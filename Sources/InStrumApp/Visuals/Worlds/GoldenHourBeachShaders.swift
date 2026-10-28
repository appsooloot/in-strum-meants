/// Metal source for Golden Hour Beach: a low headland, the Ocean layer out to the breakers, white water, the
/// wash sliding up the sand, wet sand mirroring the sky, dry sand with ripple marks, Tide Lines glowing in the
/// sand, palm silhouettes and an amber keyboard. Built on SkyShaders.common and OceanShaders.common.
/// Smooth rules: no ray marching, ≤ 2 noise octaves, ≤ 24 lines per sand pixel on Smooth.
enum GoldenHourBeachShaders {
    static let source = SkyShaders.common + OceanShaders.common + """
    struct BeachU {
        float4 a;           // keys top (NDC y), unused, glitter 0…1, haze 0…1
        float4 b;           // palms 0…1, wind, line count, night 0…1
        float4 c;           // aspect, camera height (m), unused, unused
        float4 shore;       // wash front 0…1, foam from chords 0…1, smooth (1) or not (0), white water 0…1
        float4 crest[3];    // the next crests: metres beyond the break line, strength
        float4 line[48];    // across (m), out (m), half length (m), glow
        float4 lineB[48];   // hue, unused…
    };
    struct BeachOut { float4 pos [[position]]; float2 ndc; };

    constant float kWaterline = 10.0;   // metres from the camera to where the sea meets the sand
    constant float kWetBand = 5.0;      // wet sand from here back toward the camera
    constant float kBreak = 18.0;       // where the waves break

    vertex BeachOut beach_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        BeachOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float3 beachRay(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }

    float3 hueColor(float h) {
        float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return mix(float3(1.0), k, 0.55);
    }

    float segDist(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
        return length(pa - ba * h);
    }

    // Palm silhouettes at the frame's edges, swaying with the wind (timed by the swell's wrapped phases, so they
    // never jump however long the session). Returns coverage 0…1.
    float palms(float2 p, constant BeachU& b, constant OceanU& o) {
        float amount = b.b.x;
        if (amount < 0.01 || abs(p.x) < 0.5) return 0.0;
        float aspect = b.c.x, wind = b.b.y, base = b.a.x;
        float2 q = float2(p.x * aspect, p.y);
        float cover = 0.0;
        for (int i = 0; i < 3; i++) {
            float3 h = hash33(float3(float(i), 3.0, 9.0));
            if (float(i) > amount * 3.0) continue;
            float side = (i == 1) ? 1.0 : -1.0;
            float2 root = float2(side * (0.8 + 0.18 * h.x + (i == 2 ? 0.16 : 0.0)) * aspect, base - 0.05);
            float height = 1.15 + 0.35 * h.y;
            float sway = (0.012 + 0.04 * wind) * sin(o.phases[i] + h.x * 10.0);
            float2 top = root + float2(-side * (0.14 + 0.12 * h.y) + sway, height);
            float2 ctrl = root + float2(side * 0.05, height * 0.55);
            // The trunk: a gentle curve in four pieces, thinning toward the crown.
            float2 prev = root;
            for (int k = 1; k <= 4; k++) {
                float t = float(k) / 4.0;
                float2 pt = (1.0 - t) * (1.0 - t) * root + 2.0 * (1.0 - t) * t * ctrl + t * t * top;
                float w = mix(0.022, 0.011, t);
                cover = max(cover, smoothstep(w, w * 0.5, segDist(q, prev, pt)));
                prev = pt;
            }
            // The crown: seven drooping fronds.
            for (int f = 0; f < 7; f++) {
                float a = -2.6 + float(f) * 0.86 + 0.15 * sin(o.phases.w + float(f) + h.y * 5.0) * (0.4 + wind);
                float len = 0.22 + 0.08 * hash13(float3(float(i), float(f), 2.0));
                float2 dir = float2(cos(a), sin(a) * 0.6 + 0.25);
                float2 p1 = top + dir * len * 0.5;
                float2 p2 = top + dir * len + float2(0.0, -0.09 * len / 0.25);
                float d1 = segDist(q, top, p1), d2 = segDist(q, p1, p2);
                cover = max(cover, smoothstep(0.009, 0.004, min(d1, d2)));
            }
        }
        return cover;
    }

    // A low headland to the left, hazy with distance. Height above the horizon (radians) by relative azimuth.
    float headland(float azRel) {
        if (azRel < -0.95 || azRel > -0.22) return -1.0;
        float x = (azRel + 0.95) / 0.73;
        float hump = pow(sin(3.14159 * x), 0.6) * (0.75 + 0.25 * x);
        return (0.6 + 2.2 * hump + 0.35 * fbm3(float3(azRel * 9.0, 2.0, 5.0), 2)) * 0.0174533;
    }

    fragment ColorDepth beach_fragment(BeachOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant BeachU& b [[buffer(1)]],
                                       constant OceanU& o [[buffer(2)]]) {
        ColorDepth out;
        float2 p = in.ndc;
        if (p.y < b.a.x) {   // under the keyboard
            out.color = float4(0, 0, 0, 1); out.depth = float4(0.1, 0, 0, 1);
            return out;
        }
        float3 d = beachRay(p, u);
        float alt = asin(clamp(d.z, -1.0, 1.0)), az = atan2(d.x, d.y);
        float camAz = atan2(u.forward.x, u.forward.y);
        float azRel = az - camAz;
        if (azRel > 3.14159) azRel -= 6.28318;
        if (azRel < -3.14159) azRel += 6.28318;
        float haze = b.a.w, night = b.b.w;
        float3 horizon = u.horizon.rgb, zenith = u.zenith.rgb;
        float3 hazeCol = horizon * (1.02 + 0.1 * night);
        float palm = palms(p, b, o);
        float3 palmCol = zenith * 0.05 + horizon * 0.03;

        float3 col;
        float depth = 1.0;
        if (alt >= 0.0) {
            float hl = headland(azRel);
            bool hit = alt < hl;
            if (!hit && palm < 0.01) discard_fragment();
            if (hit) {
                float3 c = mix(horizon, zenith, 0.4) * 0.3 + o.sunColor.rgb * 0.02 * o.sun.w;
                col = mix(c, hazeCol, saturate(0.45 + 0.4 * haze) * (0.6 + 0.4 * exp(-alt / 0.02)));
                depth = 0.98;
            } else {
                float mm;
                col = skyRadiance(d, u, mm);
            }
        } else {
            float hcam = b.c.y;
            float t = hcam / max(-d.z, 1e-4);
            float3 P = d * t;
            float2 fwd = normalize(u.forward.xy), rgt = float2(fwd.y, -fwd.x);
            float f = dot(P.xy, fwd), s = dot(P.xy, rgt);
            float2 q = float2(s, f);
            float front = kWaterline - b.shore.x * kWetBand;
            // Both lights, each by its own weight (never an either/or switch, so dusk crosses to moonlight smoothly).
            float lightW = saturate(o.sun.w + o.moon.w);
            float3 lightCol = (o.sunColor.rgb * o.sun.w + o.moonColor.rgb * o.moon.w) / max(o.sun.w + o.moon.w, 1e-3);
            if (f > kWaterline) {
                // The sea: swells steepen as they near the break; white water between the break and the shore.
                float2 slope = oceanSlope(q, o);
                float shoal = smoothstep(kBreak + 25.0, kBreak, f);
                slope *= 1.0 + 1.2 * shoal;
                float white = 0.0;
                for (int i = 0; i < 3; i++) {
                    float cf = kBreak + b.crest[i].x;
                    float band = exp(-((f - cf) * (f - cf)) / 2.2);
                    white += b.crest[i].y * band * smoothstep(kBreak + 30.0, kBreak + 2.0, cf);
                    slope.y += b.crest[i].y * band * 0.35 * shoal;
                }
                float surge = b.shore.w * smoothstep(kWaterline, kWaterline + 1.0, f) * smoothstep(kBreak + 2.0, kBreak - 2.0, f);
                float lace = vnoise3(float3(q * float2(1.3, 2.4), 3.0 * sin(o.phases.x)));
                white = saturate(white + surge * (0.4 + 0.6 * lace));
                float3 nrm = oceanNormal(slope, fwd, rgt);
                col = oceanShade(d, nrm, q, f, u, o);
                float foamGold = b.shore.y;
                float3 foamCol = (horizon * 0.55 + 0.35) * (0.6 + 0.6 * lightW) + lightCol * 0.25 * lightW;
                foamCol = mix(foamCol, foamCol * float3(1.15, 0.95, 0.7) + o.sunColor.rgb * 0.3, foamGold);
                col = mix(col, foamCol, white * (0.55 + 0.35 * foamGold));
                // Spray glints on golden foam.
                float spark = smoothstep(0.82, 0.95, vnoise3(float3(q * 6.0, 5.0 * sin(o.phases.y))));
                col += lightCol * spark * white * foamGold * 1.5 * lightW;
                depth = saturate(f / 60.0);
            } else {
                // The sand: wet below the highest recent wash (a mirror), dry beyond it.
                float wetTop = kWaterline - kWetBand;
                float wet = smoothstep(wetTop - 0.6, wetTop + 0.6, f);
                float ripple = 0.5 + 0.5 * sin(f * 11.0 + 2.0 * vnoise3(float3(q * 0.7, 1.0)) + s * 0.8);
                float3 sandDry = float3(0.62, 0.50, 0.36) * (0.92 + 0.08 * ripple);
                float3 sandWet = float3(0.16, 0.12, 0.09);
                float3 sky = mix(zenith, horizon, 0.7);
                float3 direct = o.sunColor.rgb * saturate(o.sun.z * 3.0 + 0.15) * o.sun.w
                              + o.moonColor.rgb * saturate(o.moon.z * 3.0 + 0.15) * o.moon.w;
                float3 dryCol = sandDry * (sky * 0.55 + direct * 0.7 + 0.02);
                // Wet sand reflects the sky (slightly rough) and the light's path.
                float2 rough = (float2(vnoise3(float3(q * 3.0, 2.0)), vnoise3(float3(q * 3.0 + 7.0, 4.0))) - 0.5) * 0.06;
                float3 n = normalize(float3(rough, 1.0));
                float3 rd = reflect(d, n);
                rd.z = max(rd.z, 0.002);
                float mm;
                float3 refl = skyRadiance(normalize(rd), u, mm);
                float fres = 0.25 + 0.6 * pow(1.0 - saturate(-d.z), 3.0);
                float3 wetCol = mix(sandWet * (sky * 0.4 + 0.02), refl, fres);
                float sdS = saturate(dot(rd, o.sun.xyz)), sdM = saturate(dot(rd, o.moon.xyz));
                float3 spec = o.sunColor.rgb * (pow(sdS, 90.0) * 1.4 + pow(sdS, 12.0) * 0.12) * o.sun.w
                            + o.moonColor.rgb * (pow(sdM, 90.0) * 1.4 + pow(sdM, 12.0) * 0.12) * o.moon.w;
                wetCol += spec * (0.5 + 0.5 * b.a.z);
                col = mix(dryCol, wetCol, wet);
                // The wash: a thin sheet of water up to its front, lacy foam along its edge.
                if (f > front) {
                    float3 sheet = mix(refl, horizon * 0.7 + 0.2, 0.25);
                    col = mix(col, sheet, 0.55);
                    float edge = smoothstep(0.9, 0.0, f - front);
                    float lacy = smoothstep(0.35, 0.75, vnoise3(float3(q * float2(2.2, 4.0), 2.0 * sin(o.phases.z))));
                    col = mix(col, (horizon * 0.5 + 0.4) * (0.7 + 0.5 * lightW), edge * (0.35 + 0.5 * lacy));
                }
                // Tide Lines glowing in the sand.
                int count = int(b.b.z + 0.5);
                float3 glow = float3(0);
                for (int i = 0; i < 48; i++) {
                    if (i >= count) break;
                    float4 ln = b.line[i];
                    // Drawn deeper than wide (÷4 along the view) so foreshortening leaves a readable stroke.
                    float dx = max(abs(s - ln.x) - ln.z, 0.0), dy = (f - ln.y) * 0.25;
                    float dist2 = dx * dx + dy * dy;
                    if (dist2 > 0.09) continue;
                    float core = exp(-dist2 / 0.004), halo = exp(-dist2 / 0.03) * 0.4;
                    glow += hueColor(b.lineB[i].x) * (core + halo) * ln.w;
                }
                col += glow * (1.2 + 0.8 * night);
                depth = saturate(f / 60.0);
            }
            // Haze over the sea, thicker far away.
            col = mix(col, hazeCol, saturate(haze * 0.7 * (1.0 - exp(-f / 120.0))));
        }
        col = mix(col, palmCol, palm);
        if (palm > 0.5) depth = 0.03;
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, light).
    struct BeachKey { float4 rect; float4 info; };
    struct BeachKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex BeachKeyOut beach_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BeachKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        BeachKey k = keys[iid];
        BeachKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth beach_keys_fragment(BeachKeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.006, 0.004, 0.003) : float3(0.05, 0.04, 0.03);
        float sheen = pow(in.uv.y, 6.0) * (black ? 0.05 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 amber = float3(1.0, 0.68, 0.3);
        float3 c = base + amber * sheen * (0.4 + light) + amber * glow * (1.6 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.1, 0, 0, 1);
        return o;
    }
    """
}
