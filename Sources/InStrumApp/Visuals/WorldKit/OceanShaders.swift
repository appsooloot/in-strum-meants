import simd
import InStrumCore

/// Metal source for the shared Ocean layer (both coasts): an analytic sea of four swell components plus chop,
/// reflecting the Living Sky with Fresnel, the sun's and the moon's glitter paths blended by each light's
/// strength, crest foam and golden-hour translucence. Everything that moves is driven by the swell's wrapped
/// phases, never by a raw clock, so the sea stays smooth however long the session.
/// Smooth rules: no ray marching; chop noise is 2 octaves on Smooth, 3 on High and Ultra.
enum OceanShaders {
    static let common = """
    struct OceanU {
        float4 phases;      // four swell components (radians, wrapped)
        float4 sun;         // direction, glitter weight 0…1
        float4 sunColor;    // rgb, translucence weight 0…1
        float4 moon;        // direction, glitter weight 0…1
        float4 moonColor;   // rgb, glitter amount 0…1
        float4 params;      // swell scale, chop, haze, octaves
    };

    // Swell components in the shore's frame (x across, y out to sea): directions, wavenumbers and heights.
    constant float2 kSwellDir[4] = { float2(0.0, -1.0), float2(0.35, -0.94), float2(-0.42, -0.91), float2(0.15, -0.99) };
    constant float kSwellK[4] = { 0.11, 0.08, 0.17, 0.26 };
    constant float kSwellA[4] = { 0.22, 0.15, 0.08, 0.05 };

    /// Surface slope (d height / d across, d height / d out) at q = (across, out) metres.
    float2 oceanSlope(float2 q, constant OceanU& o) {
        float2 g = float2(0);
        float scale = o.params.x;
        for (int i = 0; i < 4; i++) {
            float k = kSwellK[i], a = kSwellA[i] * scale;
            float ph = dot(kSwellDir[i], q) * k - o.phases[i];
            g += a * k * kSwellDir[i] * cos(ph);
        }
        // Chop: noise that sloshes in small circles with the swell (periodic, so it never jumps).
        float chop = o.params.y;
        int octaves = int(o.params.w + 0.5);
        float2 drift = float2(cos(o.phases.z), sin(o.phases.z)) * 0.6;
        float2 drift2 = float2(sin(o.phases.w), cos(o.phases.w)) * 0.35;
        float2 c = q * float2(0.55, 0.32) + drift;
        g += (float2(vnoise3(float3(c, 1.7)), vnoise3(float3(c + 5.3, 4.1))) - 0.5) * chop;
        float2 c2 = q * float2(1.6, 0.9) + drift2 + 11.0;
        g += (float2(vnoise3(float3(c2, 7.3)), vnoise3(float3(c2 + 3.1, 2.2))) - 0.5) * chop * 0.55;
        if (octaves > 2) {
            float2 c3 = q * float2(4.3, 2.5) - drift * 1.7 + 23.0;
            g += (float2(vnoise3(float3(c3, 5.5)), vnoise3(float3(c3 + 8.7, 6.6))) - 0.5) * chop * 0.3;
        }
        return g;
    }

    /// The shore-frame slope as an east-north-up normal.
    float3 oceanNormal(float2 slope, float2 fwd, float2 rgt) {
        return normalize(float3(-(slope.x * rgt.x + slope.y * fwd.x), -(slope.x * rgt.y + slope.y * fwd.y), 1.0));
    }

    /// One light's glitter path on the water: a soft sheen broken into glints.
    float3 glitterPath(float3 d, float3 nrm, float2 q, float far, float3 L, float3 color, float weight, float glitter,
                       constant OceanU& o) {
        if (weight < 0.001 || L.z < -0.1) return float3(0);
        float2 g = float2(vnoise3(float3(q * 0.9, 3.0 * sin(o.phases.x) + 1.0)), vnoise3(float3(q * 0.9 + 13.0, 3.0 * cos(o.phases.y)))) - 0.5;
        float3 mn = normalize(nrm + float3(g.x * 0.25, g.y * 0.25, 0));
        float sd = saturate(dot(reflect(d, mn), L));
        float sparkle = smoothstep(0.6 - 0.22 * glitter, 0.8, vnoise3(float3(q * 2.2, 4.0 * sin(o.phases.y) + 2.0 * cos(o.phases.z))));
        float spec = pow(sd, 700.0) * sparkle * (2.0 + 6.0 * glitter) * smoothstep(400.0, 40.0, far) + pow(sd, 60.0) * 0.2;
        return color * spec * weight * (0.35 + 0.65 * glitter);
    }

    /// The sea's colour along ray d, hitting the surface with normal nrm at q, `far` metres out.
    float3 oceanShade(float3 d, float3 nrm, float2 q, float far, constant SkyU& u, constant OceanU& o) {
        float3 rd = reflect(d, nrm);
        rd.z = max(rd.z, 0.002);
        rd = normalize(rd);
        float mm;
        float3 refl = skyRadiance(rd, u, mm);
        float cosT = saturate(-dot(d, nrm));
        float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
        float3 deep = u.zenith.rgb * 0.05 + u.horizon.rgb * 0.05 + float3(0.002, 0.008, 0.010);
        float3 col = mix(deep, refl, fres);
        // Golden hour: a low sun ahead shines through the wave faces that lean toward you.
        float2 dh = normalize(d.xy + 1e-5);
        float face = saturate(dot(nrm.xy, -dh) * 6.0);
        float ahead = saturate(dot(normalize(o.sun.xy + 1e-5), dh));
        col += float3(0.10, 0.42, 0.33) * o.sunColor.w * face * ahead * 0.22 * smoothstep(250.0, 20.0, far);
        float glitter = o.moonColor.w;
        col += glitterPath(d, nrm, q, far, o.sun.xyz, o.sunColor.rgb * 2.5, o.sun.w, glitter, o);
        col += glitterPath(d, nrm, q, far, o.moon.xyz, o.moonColor.rgb, o.moon.w, glitter, o);
        // Crest foam where the surface is steep (more of it in a storm).
        float steep = length(nrm.xy);
        col = mix(col, float3(0.85, 0.88, 0.9) * (u.horizon.rgb * 0.6 + 0.25), smoothstep(0.18, 0.32, steep) * 0.6);
        return col;
    }
    """
}

/// The ocean's two lights, each weighted smoothly by its own altitude (never an either/or switch, so the light
/// on the water crosses from sun to moon without a snap).
enum OceanLight {
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Directions with glitter weights 0…1 in `.w`, and colours. The sun's colour warms as it sinks.
    static func lights(_ s: SkyState) -> (sun: SIMD4<Float>, sunColor: SIMD3<Float>, moon: SIMD4<Float>, moonColor: SIMD3<Float>) {
        let clouds = Double(1 - 0.8 * s.cloudCover)
        let sunW = smooth(-5, 5, s.sun.altitude) * clouds
        let dayness = smooth(-6, 2, s.sun.altitude)
        let moonW = s.moonLit * smooth(-3, 6, s.moon.altitude) * (1 - dayness) * clouds
        let k = Float(min(1, max(0, s.sun.altitude / 20)))
        let warm = SIMD3<Float>(1, 0.6, 0.32), white = SIMD3<Float>(1, 0.95, 0.85)
        return (SIMD4(SkyLayer.enu(s.sun), Float(sunW)), warm + (white - warm) * k,
                SIMD4(SkyLayer.enu(s.moon), Float(moonW)), SIMD3(0.78, 0.85, 1.0))
    }
}
