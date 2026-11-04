/// Metal source for the Living Sky (dome, sun, moon, real and procedural stars, constellation lines, the Milky Way,
/// the aurora, light pillars, clouds) and the weather layer (rain, snow, splash rings, drops on glass, fireflies,
/// diamond-dust crystals). Compiled at runtime.
/// Smooth-quality rules: no ray marching, at most 3 noise octaves (2 on Smooth); the real stars are one texture sample.
enum SkyShaders {
    /// Noise, the sky uniforms and skyRadiance(): shared by the dome and by anything that reflects the sky.
    static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct ColorDepth { float4 color [[color(0)]]; float4 depth [[color(1)]]; };

    // ---------------------------------------------------------------- noise
    float hash13(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }
    float3 hash33(float3 p) {
        p = fract(p * float3(0.1031, 0.1030, 0.0973));
        p += dot(p, p.yxz + 33.33);
        return fract((p.xxy + p.yxx) * p.zyx);
    }
    float vnoise3(float3 p) {
        float3 i = floor(p), f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        float a = hash13(i), b = hash13(i + float3(1, 0, 0)), c = hash13(i + float3(0, 1, 0)), d = hash13(i + float3(1, 1, 0));
        float e = hash13(i + float3(0, 0, 1)), g = hash13(i + float3(1, 0, 1)), h = hash13(i + float3(0, 1, 1)), k = hash13(i + float3(1, 1, 1));
        return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y), mix(mix(e, g, u.x), mix(h, k, u.x), u.y), u.z);
    }
    float fbm3(float3 p, int octaves) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 3; i++) {
            if (i >= octaves) break;
            s += a * vnoise3(p);
            p = p * 2.03 + float3(17.1, 9.2, 3.7);
            a *= 0.5;
        }
        return s / (1.0 - pow(0.5, float(octaves)));
    }

    // ---------------------------------------------------------------- sky dome
    // camera: right.xyz/tanH, up.xyz/tanV, forward.xyz/time (all in east-north-up)
    // eq0..eq2: columns turning east-north-up into equatorial (x: RA 0, z: north pole)
    struct SkyU {
        float4 right, up, forward;
        float4 zenith;      // rgb, star visibility
        float4 horizon;     // rgb, cloud cover
        float4 sun;         // direction, altitude (degrees)
        float4 moon;        // direction, phase 0…1
        float4 moonInfo;    // lit fraction, earthshine, moon radius (rad), sun radius (rad)
        float4 eq0, eq1, eq2;
        float4 weather;     // mist, wind, octaves, pixel angle (rad)
        float4 extra;       // halo, dawn pastel, gust, wetness
        float4 night;       // aurora, aurora storm, constellation lines, fireflies
        float4 aurora;      // pole-ward azimuth unit vector (east, north), band base altitude (degrees), hemisphere
        float4 dust;        // diamond dust, pillar, aurora hue shift (−1 cool … +1 warm), aurora glow 0…1
        float4 ripples[8];  // along the band 0…1, age (s), strength, width
    };
    // eq0.w is 1 when the real star texture is bound (0: a 1×1 placeholder, the procedural stars carry the sky).

    // The real stars: equirectangular, x = RA (wraps), y = Dec +90 → −90 (clamped).
    constexpr sampler skyStarSampler(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    // Sirius's peak (1.0 in the texture) shows at the brightest procedural star's scale (starField's mag reaches ~9.25).
    constant float kRealStarGain = 9.0;
    // The sun's pillar: the spec's 0.35 of its (HDR, 9–14) colour is lost against the bright low sky after the tone
    // curve, so it is 1.2 (a column 6° above a 4° sun reads about 1.39× the sky beside it); the moon's keeps 0.35.
    constant float kPillarGain = 1.2;
    // Constellation lines: the spec's 0.06 all but vanishes where a figure crosses the Milky Way (Crux, Scorpius,
    // Cygnus), so 0.1: a clear blue trace at full strength, a faint one at the default 35%.
    constant float kLineGain = 0.1;

    // ---------------------------------------------------------------- optics (mirrors HaloOptics)
    float toDeg(float r) { return r * 57.2957795; }
    float toRad(float d) { return d * 0.0174532925; }
    float3 haloRing(float angleDeg, float radius) {
        float x = angleDeg - radius;
        float a = (x + 0.2) / 0.3, b = (x - 0.15) / 0.35;
        float tail = smoothstep(-0.1, 0.3, x) * exp(-max(0.0, x - 0.1) / 1.5);
        return exp(-a * a) * float3(1.0, 0.25, 0.05) + exp(-b * b) * float3(0.9, 0.85, 0.3) + tail * float3(0.55, 0.65, 0.85);
    }
    float sundogStrength(float altDeg) {
        return altDeg < -1.0 ? 0.0 : 1.0 - smoothstep(30.0, 45.0, altDeg);
    }
    /// Two rainbow-tinted spots 22°/cos(alt) either side of the light at its altitude, each with a short white tail outward.
    float3 sundogs(float3 d, float3 L, float lightAltDeg) {
        float s = sundogStrength(lightAltDeg);
        if (s <= 0.0) return float3(0);
        float altD = toDeg(asin(clamp(d.z, -1.0, 1.0)));
        float dAz = toDeg(atan2(d.x, d.y) - atan2(L.x, L.y));
        dAz -= 360.0 * floor((dAz + 180.0) / 360.0);
        float c = cos(toRad(lightAltDeg));
        float x = (abs(dAz) - 22.0 / max(c, 0.2)) * c;   // degrees outward from the dog
        float y = altD - lightAltDeg;
        float core = exp(-(x * x) / 0.81 - (y * y) / 1.96);
        float3 tint = mix(float3(1.0, 0.45, 0.2), float3(0.75, 0.85, 1.0), smoothstep(-0.8, 0.8, x));
        float tail = x > 0.0 ? exp(-x / 7.0) * exp(-(y * y) / 0.25) * 0.35 : 0.0;
        return (tint * core + float3(tail)) * s;
    }
    /// Rainbow light at `angleDeg` from the antisolar point (mirrors RainbowOptics.bow).
    float3 spectrum(float t) {
        float a = (t - 0.88) / 0.2, b = (t - 0.5) / 0.18, c = (t - 0.12) / 0.2;
        return float3(exp(-a * a), exp(-b * b), exp(-c * c));
    }
    float3 rainbowBow(float angleDeg) {
        float t1 = (angleDeg - 40.5) / 2.0;
        if (t1 >= 0.0 && t1 <= 1.0) return spectrum(t1) * smoothstep(0.0, 0.12, t1) * (1.0 - smoothstep(0.88, 1.0, t1));
        float t2 = (angleDeg - 50.5) / 3.0;
        if (t2 >= 0.0 && t2 <= 1.0) return spectrum(1.0 - t2) * smoothstep(0.0, 0.12, t2) * (1.0 - smoothstep(0.88, 1.0, t2)) * 0.35;
        return float3(0.0);
    }
    float beltOfVenus(float sunAltDeg) {
        return smoothstep(-6.0, -4.0, sunAltDeg) * (1.0 - smoothstep(0.0, 1.0, sunAltDeg));
    }
    float3 starField(float3 v, float pixelAngle, float time, float visibility) {
        const float scale = 90.0;
        float3 p = v * scale;
        float3 cell = floor(p);
        float3 r = hash33(cell);
        if (r.x > 0.30) return float3(0);                       // most cells are empty
        float3 star = cell + 0.15 + 0.7 * hash33(cell + 7.7);
        float d = length(p - star);
        float radius = max(0.9 * pixelAngle * scale, 0.04);
        float mag = pow(r.y, 7.0) * 9.0 + 0.25 * r.y;            // a few bright stars, many faint ones
        float twinkle = 0.82 + 0.18 * sin(time * (1.7 + 4.0 * r.z) + r.z * 40.0);
        float3 tint = mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.86, 0.7), r.z);
        return tint * mag * twinkle * exp(-(d * d) / (radius * radius)) * visibility;
    }

    float3 milkyWay(float3 v, int octaves, float visibility) {
        const float3 ngp = float3(-0.8676, -0.1981, 0.4560);    // galactic north pole (RA 192.86°, Dec 27.13°)
        const float3 gc = float3(-0.0548, -0.8734, -0.4838);    // galactic centre (RA 266.41°, Dec −28.94°)
        float b = asin(clamp(dot(v, ngp), -1.0, 1.0));
        float band = exp(-(b * b) / (0.2 * 0.2));
        if (band < 0.01) return float3(0);
        float toCentre = 0.5 + 0.5 * dot(v, gc);
        float centre = 0.3 + 0.7 * toCentre * toCentre;
        float n = fbm3(v * 5.0, octaves);
        float lane = exp(-(b * b) / (0.035 * 0.035)) * smoothstep(0.35, 0.8, fbm3(v * 9.0 + 3.1, max(octaves - 1, 1)));
        float glow = band * centre * (0.35 + 0.9 * n) * (1.0 - 0.75 * lane);
        return float3(0.92, 0.88, 1.0) * glow * 0.22 * visibility;
    }

    /// The real stars and the constellation lines along equatorial direction `v` (one bilinear sample). The texture
    /// stores the square root of the light, so it is squared back here.
    float3 realStars(float3 v, texture2d<float> stars, float time, float lines, float visibility) {
        float ra = atan2(v.y, v.x);
        ra = ra < 0.0 ? ra + 6.2831853 : ra;
        float dec = asin(clamp(v.z, -1.0, 1.0));
        float2 uv = float2(ra / 6.2831853, 0.5 - dec / 3.14159265);
        float4 t = stars.sample(skyStarSampler, uv, level(0.0));
        float3 light = t.rgb * t.rgb;
        // A twinkle hashed over the sky in cells smaller than a degree and smoothed between them (so a star's footprint
        // never splits on a cell edge, and RA 0/360 has no seam): 0.8–1.0, flickering at a few hertz.
        float twinkle = 0.8 + 0.2 * vnoise3(v * 80.0 + float3(0.0, 0.0, time * 3.0));
        float3 col = light * kRealStarGain * twinkle * visibility;
        col += float3(0.55, 0.65, 0.9) * t.a * kLineGain * lines * visibility;
        return col;
    }

    /// The pole-ward aurora (spec §6.3). The band's base is a great circle through the points 90° either side of the
    /// pole-ward azimuth, tilted up to the base altitude A over the pole-ward horizon (so it stands A° up there and
    /// comes down to the horizon at the band's ends; at A near 90° it arches through the zenith). Two thin curtains
    /// rise from it with an exponential profile, striped by vertical rays (noise along the band only).
    float3 auroraLight(float3 d, constant SkyU& u, float time, int octaves) {
        float2 ph = u.aurora.xy;
        float3 P = float3(ph / max(length(ph), 1e-4), 0.0);
        float3 W = float3(P.y, -P.x, 0.0);
        float A = toRad(clamp(u.aurora.z, 0.5, 89.0));
        float3 B = P * cos(A) + float3(0.0, 0.0, sin(A));
        float3 U = float3(0.0, 0.0, cos(A)) - P * sin(A);
        float along = atan2(dot(d, W), dot(d, B));            // 0 mid-band, ±π/2 at its ends on the horizon
        float ends = 1.0 - smoothstep(1.2, 1.5708, abs(along));
        if (ends <= 0.0) return float3(0);
        float h = toDeg(asin(clamp(dot(d, U), -1.0, 1.0)));     // degrees above the base
        float crown = 1.0 - smoothstep(55.0, 80.0, h);
        if (crown <= 0.0 || h < -14.0) return float3(0);   // well below the base the light is gone
        float pos = 0.5 + along / 3.14159265;                    // 0…1 along the band
        float storm = saturate(u.night.y);
        float hueShift = clamp(u.dust.z, -1.0, 1.0), glow = saturate(u.dust.w);
        float warm = max(hueShift, 0.0), cool = max(-hueShift, 0.0);

        // Ripples: each a bulge and a brightness pulse travelling outward both ways from where it started.
        float pulse = 0.0;
        for (int i = 0; i < 8; i++) {
            float4 r = u.ripples[i];
            if (r.z < 0.001) continue;
            float w = max(r.w, 0.01), travel = 0.12 * max(r.y, 0.0);
            float a = (pos - (r.x - travel)) / w, b = (pos - (r.x + travel)) / w;
            pulse += max(exp(-a * a), exp(-b * b)) * r.z;
        }
        pulse = min(pulse, 1.0);

        float t = time;
        float wobble = (vnoise3(float3(along * 3.0, t * 0.04, 7.3)) - 0.5) * 5.0;   // one octave, degrees
        float scale = 8.0 + 6.0 * storm;
        float sharp = saturate(0.35 + 0.45 * storm + 0.35 * glow);
        float3 green = mix(float3(0.25, 1.0, 0.45), float3(0.35, 0.55, 1.0), 0.6 * cool);
        float3 top = mix(float3(0.95, 0.25, 0.4), float3(0.55, 0.35, 1.0), cool);
        float topW = storm + 0.7 * warm + 0.5 * cool;
        float3 fringe = mix(mix(float3(0.6, 0.35, 1.0), float3(1.0, 0.78, 0.3), warm), float3(0.45, 0.4, 1.0), cool);
        float fringeW = storm * storm + 0.6 * warm + 0.4 * cool;

        float3 col = float3(0);
        float nearRays = 0.5;
        for (int c = 0; c < 2; c++) {
            float seed = c == 0 ? 0.0 : 31.0;
            // The second curtain stands 7° higher, behind the first; a ripple pushes the base down 3° (a bulge).
            float hb = h - (c == 0 ? 0.0 : 7.0) - wobble * (c == 0 ? 1.0 : 0.7) + 3.0 * pulse;
            float profile = hb < 0.0 ? exp(hb / 1.2) : exp(-hb / scale);
            float topP = hb > 0.0 ? smoothstep(2.0, scale, hb) * exp(-hb / (scale * 2.2)) : 0.0;
            float f = hb + 0.8;
            float fringeP = exp(-(f * f) / 1.5);
            // Rays: fbm along the band (3 octaves, 2 on Smooth); the far curtain takes one octave of its own above
            // Smooth and shares the near one's on Smooth.
            float n = c == 0 ? fbm3(float3(along * 38.0 + t * 0.05, t * 0.12, seed), octaves)
                             : (octaves > 2 ? vnoise3(float3(along * 30.0 - t * 0.04, t * 0.1, seed)) : nearRays);
            if (c == 0) nearRays = n;
            float rays = mix(0.6 + 0.4 * n, smoothstep(0.42, 0.68, n), sharp);
            float3 sheet = green * profile + top * (topW * topP) + fringe * (fringeW * fringeP);
            col += sheet * rays * (c == 0 ? 1.0 : 0.5);
        }
        // A full aurora peaks near 0.2 linear (about 0.35 of a day sky's luminance); the glow lifts it up to 1.6×, a
        // ripple's pulse up to 1.6× where it passes (Curtain Lights sends them through the flash limiter).
        return col * 0.25 * u.night.x * ends * crown * (1.0 + 0.6 * glow) * (1.0 + 0.6 * pulse);
    }

    /// A light pillar: a column through a light of angular radius `radius`, 1.5× as wide, fading exp(−|Δalt|/6°)
    /// from the light's edge.
    float lightPillar(float3 d, float alt, float3 L, float radius) {
        float lAlt = asin(clamp(L.z, -1.0, 1.0));
        float dAz = atan2(d.x, d.y) - atan2(L.x, L.y);
        dAz -= 6.2831853 * floor((dAz + 3.14159265) / 6.2831853);
        float x = dAz * cos(alt) / max(radius * 1.5, 1e-4);
        float dy = max(abs(alt - lAlt) - radius, 0.0);
        return exp(-x * x) * exp(-toDeg(dy) / 6.0);
    }

    /// The sky's light in direction `d` (alt ≥ 0): gradient, sunset band, stars, Milky Way, aurora, moon, pillars,
    /// clouds, sun. `moonMask` returns how much of the moon disc covers the ray. Shared by the dome and by reflections.
    /// `stars` is the real star texture (fragment texture 0; a 1×1 placeholder while it builds, with u.eq0.w = 0).
    float3 skyRadiance(float3 d, constant SkyU& u, thread float& moonMask, texture2d<float> stars) {
        float alt = asin(clamp(d.z, -1.0, 1.0));
        int octaves = int(u.weather.z + 0.5);
        float rainbow = (u.weather.z - float(octaves)) / 0.45;   // the fraction carries the rainbow
        float time = u.forward.w, mist = u.weather.x, cloudCover = u.horizon.w, starVis = u.zenith.w;
        float3 S = u.sun.xyz, M = u.moon.xyz;
        float sunAlt = u.sun.w;
        // A narrow horizon band under a clean zenith colour (mixing them over the whole height turns them grey).
        float band = exp(-max(alt, 0.0) / (0.2 + 0.25 * mist));
        float3 col = mix(u.zenith.rgb, u.horizon.rgb, band);
        col = mix(col, u.horizon.rgb * 1.05, mist * 0.6 * exp(-max(alt, 0.0) / 0.12));

        // Sunset band and sun glow.
        float sunDot = dot(d, S), sunAngle = acos(clamp(sunDot, -1.0, 1.0));
        float low = saturate(1.0 - abs(sunAlt) / 15.0);
        col += float3(0.9, 0.42, 0.14) * low * 0.55 * exp(-sunAngle / 0.45) * exp(-max(alt, 0.0) / 0.25);
        if (sunAlt > -2.0) {
            col += float3(1.0, 0.85, 0.65) * 0.45 * exp(-sunAngle / 0.08) * saturate((sunAlt + 2.0) / 4.0);
        }

        // Stars and the Milky Way, turned by sidereal time and latitude.
        float3x3 eq = float3x3(u.eq0.xyz, u.eq1.xyz, u.eq2.xyz);
        float3 v = eq * d;
        float above = smoothstep(0.0, 0.17, alt);
        if (starVis > 0.001 && alt > 0.0) {
            float3 procedural = starField(v, u.weather.w, time, starVis);
            float3 catalogue = float3(0);
            if (u.eq0.w > 0.5) {
                // The real stars lead; the procedural field stays as the faint background.
                catalogue = realStars(v, stars, time, saturate(u.night.z), starVis);
                procedural *= 0.45;
            }
            col += (procedural + catalogue + milkyWay(v, octaves, starVis)) * above;
        }

        // The aurora, pole-ward, in front of the stars (clouds hide it below).
        if (u.night.x > 0.001 && alt > 0.0) {
            col += auroraLight(d, u, time, octaves) * above;
        }

        // Moon: a lit sphere with its phase terminator toward the sun, plus earthshine.
        float moonR = u.moonInfo.z;
        float mDot = dot(d, M);
        float3 o3 = (d - M * mDot) / moonR;
        float r2 = dot(o3, o3);
        moonMask = 0.0;
        if (mDot > 0.0 && r2 < 1.0 && M.z > -0.05) {
            float3 n = o3 - M * sqrt(1.0 - r2);
            float3 toSun = S - M * dot(S, M);
            float ts = length(toSun);
            float3 tdir = ts > 1e-5 ? toSun / ts : u.up.xyz;
            float E = 6.2831853 * u.moon.w;
            float3 L = M * cos(E) + tdir * sin(E);
            float lit = smoothstep(-0.03, 0.06, dot(n, L));
            float maria = 0.78 + 0.22 * fbm3(o3 * 3.0 + 11.0, 2);
            float limb = 0.75 + 0.25 * sqrt(1.0 - r2);
            float edge = smoothstep(1.0, 0.92, r2);
            float3 moonCol = float3(1.0, 0.97, 0.9) * 1.6 * maria * limb * (lit + u.moonInfo.y);
            moonMask = edge;
            col = mix(col, moonCol + col * 0.3 * (1.0 - lit), edge);
        }
        if (M.z > -0.05) {
            float moonAngle = acos(clamp(mDot, -1.0, 1.0));
            float haze = 0.10 * exp(-moonAngle / 0.05) + (0.025 + 0.05 * mist) * exp(-moonAngle / 0.3);
            col += float3(0.7, 0.78, 0.95) * u.moonInfo.x * haze * (1.0 - moonMask) * saturate(M.z * 4.0 + 0.2);
        }

        // Ice halos: the 22° ring (and the faint 46° one in heavy ice) with sundogs around the sun; paler, near
        // colourless ones around a bright moon. A fraction of the sky's own brightness, so nothing flashes.
        float halo = u.extra.x;
        if (halo > 0.001 && alt > 0.0) {
            float skyLum = dot(col, float3(0.2126, 0.7152, 0.0722));
            if (sunAlt > -1.0) {
                float ang = toDeg(sunAngle);
                float3 h = haloRing(ang, 22.0) * 0.12 + haloRing(ang, 46.0) * 0.05 * saturate((halo - 0.7) / 0.3);
                h += sundogs(d, S, sunAlt) * 0.8;
                col += h * halo * saturate((sunAlt + 1.0) / 3.0) * (0.25 + skyLum);
            }
            if (M.z > 0.0 && u.moonInfo.x > 0.6) {
                float moonAlt = toDeg(asin(clamp(M.z, -1.0, 1.0)));
                float ang = toDeg(acos(clamp(mDot, -1.0, 1.0)));
                float3 h = haloRing(ang, 22.0) * 0.10 + sundogs(d, M, moonAlt) * 0.35;
                float l = dot(h, float3(0.2126, 0.7152, 0.0722));
                col += mix(float3(l), h, 0.25) * float3(0.85, 0.9, 1.0) * halo * smoothstep(0.6, 0.9, u.moonInfo.x) * (0.3 + skyLum);
            }
        }

        // Light pillars in diamond dust: over and under a low sun (−2°…12°), and a bright moon (lit > 0.3).
        float pillar = u.dust.y;
        if (pillar > 0.001) {
            float sunW = smoothstep(-2.0, -1.0, sunAlt) * (1.0 - smoothstep(11.0, 12.0, sunAlt));
            if (sunW > 0.0) {
                float3 sunCol = mix(float3(9.0, 4.5, 2.0), float3(14.0, 12.5, 10.5), saturate(sunAlt / 12.0));
                col += sunCol * (kPillarGain * pillar * sunW) * lightPillar(d, alt, S, u.moonInfo.w) * (1.0 - moonMask);
            }
            float moonW = smoothstep(0.3, 0.4, u.moonInfo.x) * saturate(M.z * 10.0 + 0.5);
            if (moonW > 0.0) {
                float3 moonCol = float3(1.0, 0.97, 0.9) * 1.6 * u.moonInfo.x;
                col += moonCol * (0.35 * pillar * moonW) * lightPillar(d, alt, M, u.moonInfo.z) * (1.0 - moonMask);
            }
        }

        // The Belt of Venus: at twilight, a pink band 5–20° up opposite the sun over the blue-grey of Earth's shadow.
        float belt = beltOfVenus(sunAlt);
        if (belt > 0.0 && alt > 0.0) {
            float2 hs = S.xy / max(length(S.xy), 1e-4), hd = d.xy / max(length(d.xy), 1e-4);
            float away = saturate(-dot(hs, hd));
            away *= away;
            float altDeg = toDeg(alt);
            float band = smoothstep(4.0, 7.0, altDeg) * (1.0 - smoothstep(16.0, 22.0, altDeg));
            col += float3(1.0, 0.62, 0.70) * 0.12 * belt * (1.0 + u.extra.y) * band * away;
            float shadow = (1.0 - smoothstep(2.0, 5.0, altDeg)) * away * belt;
            float l = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = mix(col, l * float3(0.8, 0.86, 1.02), 0.6 * shadow) * (1.0 - 0.25 * shadow);
        }

        // Clouds: a drifting layer lit by the sun or the moon.
        if (cloudCover > 0.01 && alt > 0.0) {
            float2 uv = d.xy / (d.z + 0.12) * 0.55 + float2(time * 0.004 * (0.3 + u.weather.y), time * 0.0015);
            float n = fbm3(float3(uv * 2.2, time * 0.003), octaves);
            // Calibrated so light cloud leaves most of the sky clear and overcast closes it.
            float threshold = 0.85 - 0.6 * cloudCover;
            float density = smoothstep(threshold, threshold + 0.12 + 0.1 * cloudCover, n) * smoothstep(0.0, 0.08, alt);
            bool day = sunAlt > -6.0;
            float3 L = day ? S : M;
            float lightAmt = day ? saturate((sunAlt + 6.0) / 12.0) : u.moonInfo.x * 0.35;
            float facing = pow(saturate(dot(d, L)), 6.0);
            float baseLum = dot(mix(u.zenith.rgb, u.horizon.rgb, 0.4), float3(0.2126, 0.7152, 0.0722));
            float3 base = mix(mix(u.zenith.rgb * 0.7 + 0.02, u.horizon.rgb * 0.9, 0.4), baseLum * float3(0.92, 0.97, 1.06), 0.5);
            float3 lightCol = day ? mix(float3(1.0, 0.62, 0.38), float3(1.0, 0.98, 0.95), saturate(sunAlt / 20.0)) : float3(0.55, 0.62, 0.8);
            // Pastel dawns light the cloud undersides pink.
            float pastel = u.extra.y * smoothstep(-10.0, -6.0, sunAlt) * (1.0 - smoothstep(4.0, 8.0, sunAlt));
            lightCol = mix(lightCol, float3(1.0, 0.68, 0.78), 0.7 * pastel);
            float3 cloud = base * (0.55 + 0.45 * lightAmt) + lightCol * lightAmt * (0.25 + 0.9 * facing) * (1.0 - 0.6 * density);
            col = mix(col, cloud, density * (1.0 - moonMask * 0.0));
        }

        // Rainbows: the primary bow 42° and the secondary 51° from the point opposite the sun, a little light
        // added to the sky (and dimmed where cloud is thick), so nothing flashes.
        if (rainbow > 0.002 && sunAlt > 0.0) {
            float anti = toDeg(acos(clamp(dot(d, -S), -1.0, 1.0)));
            float3 bow = rainbowBow(anti);
            float inside = anti < 41.5 ? 0.05 * smoothstep(20.0, 41.5, anti) : 0.0;   // the sky inside the bow is a touch brighter
            col += (bow * 0.30 + float3(inside)) * rainbow * (1.0 - 0.5 * cloudCover);
        }

        // Sun disc last (clouds can hide it softly).
        if (sunAlt > -1.0) {
            float sunR = u.moonInfo.w;
            float disc = smoothstep(sunR, sunR * 0.85, sunAngle);
            float3 sunCol = mix(float3(9.0, 4.5, 2.0), float3(14.0, 12.5, 10.5), saturate(sunAlt / 12.0));
            col = mix(col, sunCol, disc * (1.0 - 0.85 * saturate(cloudCover - 0.4)));
        }

        return col;
    }

    """

    static let source = common + """
    struct SkyOut { float4 pos [[position]]; float2 ndc; };

    vertex SkyOut sky_dome_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        SkyOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    fragment ColorDepth sky_dome_fragment(SkyOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                          texture2d<float> stars [[texture(0)]]) {
        float3 d = normalize(u.forward.xyz + u.right.xyz * in.ndc.x * u.right.w + u.up.xyz * in.ndc.y * u.up.w);
        float moonMask = 0.0;
        float3 col = d.z < 0.0 ? u.horizon.rgb * 0.6 : skyRadiance(d, u, moonMask, stars);
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- weather
    // instance: pos.xy (NDC), size.x (length or radius), size.y (alpha); kind: 0 rain streak, 1 snow, 2 bead on glass,
    // 3 a ground streamer (blowing snow), 4 a firefly (radius of its soft glow), 5 a diamond-dust crystal
    struct Particle { float4 posSize; };
    struct WeatherU { float4 params; };   // x aspect, y kind, z tilt (dx per dy), w brightness
    struct WeatherOut { float4 pos [[position]]; float2 uv; float alpha; float kind; };

    vertex WeatherOut weather_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                     constant Particle* ps [[buffer(0)]], constant WeatherU& u [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float4 p = ps[iid].posSize;
        float2 q = c[vid];
        float kind = u.params.y;
        float2 offset;
        if (kind < 0.5) {
            float len = p.z, w = 0.0016;
            float2 dir = normalize(float2(u.params.z, -1.0));
            float2 side = float2(-dir.y, dir.x);
            offset = dir * q.y * len * 0.5 + side * q.x * w;
            offset.x /= u.params.x;
        } else if (kind > 2.5 && kind < 3.5) {
            offset = float2(q.x * p.z * 0.5, q.y * 0.0035);
        } else {
            offset = q * p.z;
            offset.x /= u.params.x;
        }
        WeatherOut o;
        o.pos = float4(p.xy + offset, 0, 1);
        o.uv = q;
        o.alpha = p.w;
        o.kind = kind;
        return o;
    }

    fragment float4 weather_fragment(WeatherOut in [[stage_in]], constant WeatherU& u [[buffer(0)]]) {
        float3 col;
        float a;
        if (in.kind < 0.5) {             // rain: a thin soft streak
            a = (1.0 - in.uv.x * in.uv.x) * smoothstep(1.0, 0.2, abs(in.uv.y)) * in.alpha;
            col = float3(0.72, 0.78, 0.9);
        } else if (in.kind < 1.5) {      // snow: a soft flake
            float r = length(in.uv);
            a = smoothstep(1.0, 0.3, r) * in.alpha;
            col = float3(0.95, 0.97, 1.0);
        } else if (in.kind > 4.5) {      // a diamond-dust crystal: a hard glint with a faint cross
            float r2 = dot(in.uv, in.uv);
            float spikes = exp(-in.uv.x * in.uv.x * 40.0) * exp(-in.uv.y * in.uv.y * 2.0)
                         + exp(-in.uv.y * in.uv.y * 40.0) * exp(-in.uv.x * in.uv.x * 2.0);
            a = saturate(exp(-r2 * 9.0) + 0.25 * spikes) * smoothstep(1.0, 0.8, sqrt(r2)) * in.alpha;
            col = float3(0.82, 0.9, 1.0);
        } else if (in.kind > 3.5) {      // a firefly: a warm core in a soft glow
            float r2 = dot(in.uv, in.uv);
            a = saturate(exp(-r2 * 16.0) + 0.35 * exp(-r2 * 4.0)) * smoothstep(1.0, 0.85, sqrt(r2)) * in.alpha;
            col = float3(1.0, 0.95, 0.45);
        } else if (in.kind > 2.5) {      // a ground streamer: a long thin wisp, thickest at its head
            float along = 0.5 + 0.5 * in.uv.x;
            a = (1.0 - in.uv.y * in.uv.y) * smoothstep(0.0, 0.35, along) * smoothstep(1.0, 0.75, along) * in.alpha;
            col = float3(0.92, 0.95, 1.0);
        } else {                          // a drop on glass: bright rim, darker lens
            float r = length(in.uv * float2(1.0, 0.85));
            float rim = smoothstep(1.0, 0.82, r) - smoothstep(0.82, 0.55, r) * 0.6;
            float glint = exp(-dot(in.uv - float2(-0.35, 0.4), in.uv - float2(-0.35, 0.4)) * 30.0);
            a = saturate(rim + glint) * in.alpha;
            col = float3(0.8, 0.86, 0.95) + glint;
        }
        return float4(col * u.params.w * a, a);
    }

    // Splash rings on water: pos.xy, radius, alpha.
    struct RingOut { float4 pos [[position]]; float2 uv; float alpha; };
    vertex RingOut ring_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Particle* rs [[buffer(0)]], constant WeatherU& u [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float4 r = rs[iid].posSize;
        RingOut o;
        o.uv = c[vid];
        o.pos = float4(r.xy + c[vid] * float2(r.z / u.params.x, r.z * 0.3), 0, 1);
        o.alpha = r.w;
        return o;
    }

    fragment float4 ring_fragment(RingOut in [[stage_in]], constant WeatherU& u [[buffer(0)]]) {
        float r = length(in.uv);
        float q = (r - 0.85) / 0.08;
        float ring = exp(-q * q);
        float a = ring * in.alpha;
        return float4(float3(0.75, 0.8, 0.9) * u.params.w * a, a);
    }
    """
}
