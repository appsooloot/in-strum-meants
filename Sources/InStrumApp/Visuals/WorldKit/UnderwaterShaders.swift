/// Metal source for the Underwater Kit (spec §7.3): shared helpers for any world under water (the submarine, and the
/// reef's lower half). `common` follows `SkyShaders.common` in a world's program (it uses its noise, `SkyU` and
/// `skyRadiance`):
///
///     static let source = SkyShaders.common + UnderwaterShaders.common + """ ... """
///
/// Conventions: metres; `depth` is below the surface (≥ 0); directions are east-north-up unit vectors (z up); a point
/// `p` is east-north-up metres with the surface at z = 0 (so the depth is −p.z); every colour is linear light, with
/// `light` the light falling on the surface (rgb, 1 = a noon sun and sky). The helpers return physical light: a world
/// sums what it draws of the sea, then multiplies by `waterAdapt(the viewer's depth)` (the eye's tone curve) before it
/// adds its lamps and living light. The water's own glow (`kWaterTint`) is set to read at a post exposure of 1.
///
///     float3 waterAbsorb(float metres)
///         Beer–Lambert transmittance through clear ocean, per channel: exp(−(0.35, 0.07, 0.03) /m × metres).
///     float3 waterLight(float depth, float3 light)
///         The light from above at `depth`: light × waterAbsorb(depth). Red is gone in the top 10 m (at 10 m it is 4%
///         of blue, relative to the surface), green by about 60 m. The three bands' mean is 1.7% of the surface's at
///         100 m (the "1% at 100 m" of the euphotic zone; 0.4% in luminance).
///     float waterAdapt(float depth)
///         The tone curve, as the eye adapts: a gain of e^(0.0229 × depth), held from 400 m down. The blue it sees
///         falls only as blue^0.236: turquoise in the shallows, deep blue at 65 m, a dim blue glow at 200 m, a deep
///         blue still readable at 400 m, and gone by 450 m (below that, only living light and lamps remain).
///     float3 waterColour(float depth, float distance, float3 light)
///         The water's own colour along a level path `distance` metres long at `depth`: the light it scatters toward
///         the eye (0 at 0 m, the open water's colour far off). Turquoise near the surface, deep blue below.
///     float3 throughWater(float3 col, float depth, float distance, float3 light)
///         Something of (already lit) colour `col`, `distance` metres away at `depth`, seen through the water.
///     float3 waterView(float3 d, float depth, float3 light)
///         Open water along `d` from `depth`: level, as waterColour far off; looking straight down, under a third as
///         bright (sunlight scatters mostly onward, down); looking up, only the water between you and the surface
///         (add snellWindow for what comes through it).
///     float3 snellWindow(float3 d, float depth, float t, float waves, float3 mirror, constant SkyU& u,
///                        texture2d<float> stars, thread float& window)
///         What reaches the eye along `d` (looking up from `depth`) from the surface: within 48.6° of the vertical,
///         the whole sky squeezed by Snell's law and sampled through skyRadiance (the sun or moon, stars and meteors in
///         it), lifted 3× (`kWindowGain`) against the water's display-set glow; beyond, the surface's mirror of
///         `mirror` (the water below as seen from just under the surface, e.g. waterView(float3(d.x, d.y, −d.z), 0.0,
///         light)), shimmering with the waves. Each colour has its own critical angle (water's dispersion: a faint
///         rainbow fringe); 2 octaves of noise wobble the surface's normal (`waves` 0 flat … 1 a storm, `t` seconds;
///         ripples finer than a pixel's patch of surface, from `u.weather.w`, settle out); Fresnel at the surface and
///         the water above you attenuate it; it fades from 20 m and is gone by 40 m. `window` returns the share of sky
///         (0 the mirror … 1 clear sky). Bind `u` and `stars` as for skyRadiance (the real star texture at fragment
///         texture 0 with `SkyLayer.bindStars`, or its placeholder: then the procedural stars carry the sky, so a world
///         at the surface is never broken by a missing texture).
///     float caustics(float3 p, float t)
///     float caustics(float3 p, float t, float footprint)
///         The dancing net of light on sand and coral: a light factor for a point lit from above (mean 1, 0.3 between
///         the lines, up to about 6 where they cross), from two layers (2 octaves) of a sine-warped cell pattern whose
///         lines are true distances to the cells' edges. Its contrast fades from 5 m and it is exactly 1 from 15 m
///         down. `footprint` (metres a pixel covers) settles lines finer than a pixel to their mean, for far or
///         grazing sand; the two-argument form takes 0.
///     float lightShafts(float2 uv, float2 lightDir, float t, float depth, float waves)
///         Soft slanted bands of light along the refracted sun or moon, drawn in 2-D: `uv` is the view in NDC-y units
///         (x × aspect, y), `lightDir` the way the light travels on screen (down the view). A band every ~0.18 units
///         across (some faint), so a porthole 1.1–1.8 units wide shows 6–10; scale `uv` down for a wider view. Each
///         flickers along its length with 1-D noise that runs down it with the surface's waves (harder in a storm);
///         they dim down the view and fade with depth (a quarter as strong at 60 m, gone by 180 m). Returns 0…~1:
///         multiply by the scattered light, waterLight(depth, light) × kWaterTint.
///
/// Smooth rules: no ray marching; at most 2 noise octaves here (the caustics' two layers, Snell's wobble); no `pow`.
enum UnderwaterShaders {
    static let common = """
    // ================================================================ the Underwater Kit (spec §7.3)
    // Clear-ocean Beer–Lambert coefficients (/m), the water's single-scattering colour, water's index per channel at
    // 656, 589 and 486 nm (dispersion widens the window for red), and the eye's adaptation (the tone curve).
    constant float3 kWaterK = float3(0.35, 0.07, 0.03);
    constant float3 kWaterTint = float3(0.08, 0.6, 0.75);
    constant float3 kWaterIOR = float3(1.331, 1.334, 1.338);
    constant float kWaterAdaptRate = 0.0229;
    constant float kWaterAdaptFloor = 400.0;
    // The caustic net: the light left between its lines, and one layer's mean (measured over many cells), so the
    // net's mean over a patch of sand is 1 (light is moved about, not made).
    constant float kCausticBase = 0.3;
    constant float kCausticMean = 0.136;
    // The sky through Snell's window is lifted against the water's own glow, which is set to read at exposure 1 (in
    // the sea the window is tens of times brighter than the water around it).
    constant float kWindowGain = 3.0;

    float3 waterAbsorb(float metres) {
        return exp(-kWaterK * max(metres, 0.0));
    }

    float3 waterLight(float depth, float3 light) {
        return light * waterAbsorb(depth);
    }

    float waterAdapt(float depth) {
        return exp(kWaterAdaptRate * clamp(depth, 0.0, kWaterAdaptFloor));
    }

    float3 waterColour(float depth, float distance, float3 light) {
        return waterLight(depth, light) * kWaterTint * (1.0 - waterAbsorb(distance));
    }

    float3 throughWater(float3 col, float depth, float distance, float3 light) {
        return col * waterAbsorb(distance) + waterColour(depth, distance, light);
    }

    /// (1 − e^−x) / x, and its limit 1 at 0.
    float uwPhi(float x) {
        return x < 1e-3 ? 1.0 - 0.5 * x : (1.0 - exp(-x)) / x;
    }

    float3 waterView(float3 d, float depth, float3 light) {
        float D = max(depth, 0.0);
        float up = clamp(d.z, -1.0, 1.0);
        // Sunlight scatters mostly onward, down: looking straight down sees a third of the level light (0.62 of it,
        // over half the path's worth of glow), looking up more.
        float phase = (0.45 + 0.275 * (1.0 + up)) / 0.725;
        float3 base = waterLight(D, light) * kWaterTint * phase;
        // Single scattering along the ray, the light growing as it rises: ∫ e^(−k(D − up·s)) e^(−k s) k ds.
        if (up <= 0.0) return base / (1.0 - up);
        float S = D / max(up, 1e-4);                     // metres to the surface
        float3 x = kWaterK * ((1.0 - up) * S);
        return base * kWaterK * S * float3(uwPhi(x.x), uwPhi(x.y), uwPhi(x.z));
    }

    /// Fresnel reflectance leaving water of index `n` into air (unpolarised) for an incidence whose cosine is
    /// `cosI`: 1 past the critical angle. `cosT` returns the refracted ray's cosine (0 when totally reflected).
    float uwFresnelOut(float cosI, float n, thread float& cosT) {
        float sinT2 = n * n * (1.0 - cosI * cosI);
        if (sinT2 >= 1.0) { cosT = 0.0; return 1.0; }
        cosT = sqrt(1.0 - sinT2);
        float rs = (n * cosI - cosT) / (n * cosI + cosT);
        float rp = (n * cosT - cosI) / (n * cosT + cosI);
        return 0.5 * (rs * rs + rp * rp);
    }

    float3 snellWindow(float3 d, float depth, float t, float waves, float3 mirror, constant SkyU& u,
                       texture2d<float> stars, thread float& window) {
        window = 0.0;
        float D = max(depth, 0.0);
        float fade = 1.0 - smoothstep(20.0, 40.0, D);
        if (d.z <= 0.02 || fade <= 0.0) return float3(0);
        float S = D / d.z;                                   // metres up the ray to the surface
        // The surface's slope where the ray meets it: two octaves of drifting noise (their lattices turned apart, so the
        // window's torn edge never follows a grid), steeper in rough water; ripples finer than the pixel's patch of
        // surface (`u.weather.w` is a pixel's angle) settle out instead of breaking into specks.
        float2 hit = d.xy * (max(D, 0.5) / d.z);
        float foot = max(D, 0.5) / d.z * u.weather.w / max(d.z, 0.05);
        float2 q = float2(0.8 * hit.x - 0.6 * hit.y, 0.6 * hit.x + 0.8 * hit.y) * 0.9 + float2(t * 0.11, -t * 0.07);
        float2 slope = float2(vnoise3(float3(q, t * 0.35)), vnoise3(float3(q + 5.2, t * 0.35 + 3.1))) - 0.5;
        float2 q2 = float2(0.28 * q.x + 0.96 * q.y, -0.96 * q.x + 0.28 * q.y) * 2.3 + 9.1;
        float k2 = 1.0 - smoothstep(0.1, 0.4, foot * 2.07);
        if (k2 > 0.0) slope += (float2(vnoise3(float3(q2, t * 0.6)), vnoise3(float3(q2 + 3.7, t * 0.6 + 1.3))) - 0.5) * (0.5 * k2);
        slope *= 0.3 * saturate(waves) * (1.0 - 0.6 * smoothstep(0.2, 0.9, foot * 0.9));
        float3 n = normalize(float3(-slope, 1.0));
        float cosI = saturate(dot(d, n));
        // Each colour leaves through its own window (water disperses a little), so the edge has a faint rainbow.
        float ctR, ctG, ctB;
        float3 R = float3(uwFresnelOut(cosI, kWaterIOR.x, ctR), uwFresnelOut(cosI, kWaterIOR.y, ctG),
                          uwFresnelOut(cosI, kWaterIOR.z, ctB));
        // The sky along green's refracted ray (held at the horizon past green's critical angle): Snell's squeeze.
        float3 sky = float3(0);
        if (R.x < 1.0) {
            float eta = kWaterIOR.y;
            float sinT2 = min(eta * eta * (1.0 - cosI * cosI), 0.9999);
            float3 a = eta * d + (sqrt(1.0 - sinT2) - eta * cosI) * n;
            a.z = max(a.z, 0.002);
            float mm;
            sky = skyRadiance(normalize(a), u, mm, stars);
        }
        // The mirror shimmers: where the wobble tips it to reflect more steeply down it darkens, shallower it brightens.
        float3 r = reflect(d, n);
        float sheen = (1.0 + d.z) / (1.0 + max(-r.z, 0.0));
        window = fade * (1.0 - R.y);
        return (sky * (kWindowGain * (1.0 - R)) + mirror * (R * sheen)) * waterAbsorb(S) * fade;
    }

    /// One layer of the caustic net: thin bright lines along the edges of jittered cells whose points wander. A first
    /// pass finds the nearest point A; a second takes the distance to A's nearest edge, to each neighbour X the
    /// bisector's distance (P→midpoint of AX along AX), so every line is as thin as the next however close two points
    /// come, with no seams where the neighbour changes.
    float uwCausticNet(float2 q, float t) {
        float2 i = floor(q), f = q - i;
        float d1 = 9.0, ha = 0.0;
        float2 ra = float2(0), ca = float2(0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 g = float2(float(x), float(y));
                float3 h = hash33(float3(i + g, 3.7));
                float2 r = g + 0.5 + 0.38 * sin(t * (0.5 + 0.6 * h.z) + 6.2831853 * h.xy) - f;
                float dd = dot(r, r);
                if (dd < d1) { d1 = dd; ha = h.z; ra = r; ca = g; }
            }
        }
        // The two nearest edges and the brightness of each (from the pair of cells it divides: some lines blaze,
        // others are faint), blended where the two meet so the brightness never jumps.
        float e1 = 9.0, e2 = 9.0, b1 = 0.0, b2 = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 g = float2(float(x), float(y));
                if (g.x == ca.x && g.y == ca.y) continue;
                float3 h = hash33(float3(i + g, 3.7));
                float2 r = g + 0.5 + 0.38 * sin(t * (0.5 + 0.6 * h.z) + 6.2831853 * h.xy) - f;
                float2 ab = r - ra;
                float len = length(ab);
                if (len < 1e-4) continue;
                float e = dot(0.5 * (ra + r), ab / len);
                float b = 0.45 + 0.55 * fract((ha + h.z) * 7.31);
                if (e < e1) { e2 = e1; b2 = b1; e1 = e; b1 = b; } else if (e < e2) { e2 = e; b2 = b; }
            }
        }
        float bright = mix(b1, b2, 0.5 * (1.0 - smoothstep(0.0, 0.12, e2 - e1)));
        // A sharp core in a soft glow.
        float core = 1.0 - smoothstep(0.0, 0.07, e1), glow = 1.0 - smoothstep(0.0, 0.22, e1);
        return (core * core + 0.3 * glow * glow) * bright;
    }

    float caustics(float3 p, float t, float footprint) {
        float depth = max(-p.z, 0.0);
        if (depth >= 15.0) return 1.0;
        // Deeper, the surface's lenses focus farther off: a wider, softer net (cells per metre).
        float scale = 1.3 / (1.0 + 0.05 * depth);
        float2 q = p.xy * scale;
        // Lines finer than the pixel's footprint (metres) settle to their average instead of shimmering.
        float fa = 1.0 - smoothstep(0.04, 0.3, max(footprint, 0.0) * scale), fb = 1.0 - smoothstep(0.04, 0.3, max(footprint, 0.0) * scale * 2.1);
        // The warped sine: the swell bends the net, so its lines curve and sway.
        float2 warp = 0.3 * float2(sin(q.y * 1.1 + t * 0.9) + 0.45 * sin(q.y * 2.7 - t * 0.6 + 1.3),
                                   sin(q.x * 1.2 - t * 0.8) + 0.45 * sin(q.x * 2.5 + t * 0.55 + 2.1));
        float a = fa > 0.0 ? mix(kCausticMean, uwCausticNet(q + warp, t), fa) : kCausticMean;
        float b = fb > 0.0 ? mix(kCausticMean, uwCausticNet(q * 2.1 - warp * 1.6 + 7.3, t * 1.4), fb) : kCausticMean;
        float c = kCausticBase + (1.0 - kCausticBase) * (a + 0.5 * b) / (1.5 * kCausticMean);
        return mix(1.0, c, 1.0 - smoothstep(5.0, 15.0, depth));
    }

    float caustics(float3 p, float t) {
        return caustics(p, t, 0.0);
    }

    /// Smooth 1-D value noise (one octave).
    float uwNoise1(float x, float seed) {
        float i = floor(x), f = x - i;
        float a = hash13(float3(i, seed, 1.7)), b = hash13(float3(i + 1.0, seed, 1.7));
        return mix(a, b, f * f * (3.0 - 2.0 * f));
    }

    float lightShafts(float2 uv, float2 lightDir, float t, float depth, float waves) {
        float D = max(depth, 0.0);
        float fade = exp(-D / 45.0) * (1.0 - smoothstep(110.0, 180.0, D));
        if (fade <= 0.001) return 0.0;
        float ll = length(lightDir);
        float2 L = ll > 1e-5 ? lightDir / ll : float2(0.0, -1.0);
        float2 P = float2(-L.y, L.x);
        float across = dot(uv, P), along = dot(uv, L);
        const float spacing = 0.18;
        float cell = floor(across / spacing);
        float flicker = 0.35 + 0.45 * saturate(waves);
        float sum = 0.0;
        for (int j = -1; j <= 1; j++) {
            float c = cell + float(j);
            float3 h = hash33(float3(c, 11.3, 2.9));
            // Each band: its own place, width, strength and a slow sway.
            float centre = (c + 0.5 + 0.6 * (h.x - 0.5)) * spacing + 0.03 * sin(t * (0.15 + 0.1 * h.y) + 6.2831853 * h.z);
            float width = spacing * (0.12 + 0.3 * h.y);
            float x = (across - centre) / width;
            float band = exp(-x * x);
            // Its brightness flickers along it, the flicker running down it with the waves.
            float n = uwNoise1(along * 1.9 - t * (0.5 + 0.9 * saturate(waves)) + c * 7.1, c);
            sum += band * (0.15 + 0.85 * h.z * h.z) * (1.0 - flicker + 2.0 * flicker * n);
        }
        // Brightest near the surface (the top of the view), dimming down it.
        float env = smoothstep(-1.6, 1.2, uv.y);
        return sum * env * env * fade;
    }

    """
}

/// The Underwater Kit's probe and test view: a program the WorldKit tests run on the GPU (and mslcheck type-checks, so
/// `UnderwaterShaders.common` is checked before any world uses it), and the CPU render harness renders.
/// - `underwater_probe_fragment`: one pixel per probe, two float4s each in fragment buffer 1 (up to 64): (kind, a, b, c)
///   and (d0, d1, d2, d3). Kinds: 0 waterAbsorb(a); 1 waterLight(a, 1); 2 waterColour(a, b, 1); 3 snellWindow(d
///   (d0…d2), depth a, t b, waves c, mirror green), with the window share in w; 4 waterAdapt(a) in x; 5 waterView(d,
///   depth a, 1); 6 lightShafts((a, b), (d0, d1), t c, depth d2, waves d3) in x; 7 caustics((a, b, c), t d0) in x.
///   Bind a SkyU at fragment buffer 0 and the stars at texture 0.
/// - `underwater_grid_fragment`: the caustics on a grid, pixel (x, y) at (x, y) × spacing (`GridU` at buffer 0).
/// - `underwater_view_fragment`: a test view of the open sea (water, Snell's window, sand with caustics, shafts) from
///   a depth, for previews (`UnderViewU` at buffer 1, SkyU at 0, stars at texture 0).
/// - `cabin_wall_fragment`: a dark cabin wall around a round hole (previews of the porthole).
enum UnderwaterProbe {
    static let source = SkyShaders.common + UnderwaterShaders.common + """
    struct UnderOut { float4 pos [[position]]; float2 ndc; };

    vertex UnderOut underwater_view_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
        UnderOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    fragment float4 underwater_probe_fragment(UnderOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                              constant float4* probes [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        int i = int(in.pos.x);
        float4 p = probes[2 * i], q = probes[2 * i + 1];
        int kind = int(p.x + 0.5);
        float3 one = float3(1.0);
        if (kind == 0) return float4(waterAbsorb(p.y), 0.0);
        if (kind == 1) return float4(waterLight(p.y, one), 0.0);
        if (kind == 2) return float4(waterColour(p.y, p.z, one), 0.0);
        if (kind == 3) {
            float window;
            float3 c = snellWindow(normalize(q.xyz), p.y, p.z, p.w, float3(0.0, 1.0, 0.0), u, stars, window);
            return float4(c, window);
        }
        if (kind == 4) return float4(waterAdapt(p.y), 0.0, 0.0, 0.0);
        if (kind == 5) return float4(waterView(normalize(q.xyz), p.y, one), 0.0);
        if (kind == 6) return float4(lightShafts(p.yz, q.xy, p.w, q.z, q.w), 0.0, 0.0, 0.0);
        return float4(caustics(float3(p.y, p.z, p.w), q.x), 0.0, 0.0, 0.0);
    }

    struct GridU { float4 a; };   // spacing (m), depth (m), time (s), unused

    fragment float4 underwater_grid_fragment(UnderOut in [[stage_in]], constant GridU& g [[buffer(0)]]) {
        float2 xy = floor(in.pos.xy) * g.a.x;
        return float4(caustics(float3(xy, -g.a.y), g.a.z), 0.0, 0.0, 0.0);
    }

    struct UnderViewU {
        float4 cam;     // view azimuth (radians), pitch (radians, up +), tan of half the vertical view, aspect (w/h)
        float4 a;       // the viewer's depth (m), time (s), waves 0…1, how far below the viewer the sand lies (m)
        float4 light;   // the light falling on the surface (rgb), the shafts' strength
        float4 shaft;   // the shafts' direction on screen (x, y), a pixel's angle (radians), unused
    };

    fragment ColorDepth underwater_view_fragment(UnderOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                                 constant UnderViewU& v [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float az = v.cam.x, pitch = v.cam.y, tanV = v.cam.z, aspect = v.cam.w;
        float3 fwd = float3(sin(az) * cos(pitch), cos(az) * cos(pitch), sin(pitch));
        float3 right = float3(cos(az), -sin(az), 0.0);
        float3 up = cross(right, fwd);
        float3 d = normalize(fwd + right * (in.ndc.x * tanV * aspect) + up * (in.ndc.y * tanV));
        float D = max(v.a.x, 0.0), t = v.a.y, waves = v.a.z, below = max(v.a.w, 0.5);
        float3 L = v.light.rgb;
        float3 col = waterView(d, D, L);
        float depthOut = 1.0;
        if (d.z > 0.0) {
            float window;
            col += snellWindow(d, D, t, waves, waterView(float3(d.x, d.y, -d.z), 0.0, L), u, stars, window);
        } else {
            // Pale sand on a level floor, lit from above through the caustics, seen through the water between.
            float s = below / max(-d.z, 1e-3);
            if (s < 150.0) {
                float3 p = float3(d.x * s, d.y * s, -(D + below));
                float footprint = s * v.shaft.z / max(-d.z, 0.05);
                float3 sand = float3(0.78, 0.72, 0.58) * waterLight(D + below, L) * caustics(p, t, footprint) * 0.85;
                float3 T = waterAbsorb(s);
                col = col * (1.0 - T) + sand * T;
                depthOut = saturate(s / 60.0);
            }
        }
        col += lightShafts(float2(in.ndc.x * aspect, in.ndc.y), v.shaft.xy, t, D, waves) * waterLight(D, L) * kWaterTint * v.light.w;
        col *= waterAdapt(D);
        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(depthOut, 0, 0, 1);
        return o;
    }

    struct WallU {
        float4 circle;  // the hole's centre (NDC x, y), its radius (NDC-y units), aspect (w/h)
        float4 light;   // the cabin light (rgb), unused
    };

    fragment ColorDepth cabin_wall_fragment(UnderOut in [[stage_in]], constant WallU& w [[buffer(0)]]) {
        float2 q = (in.ndc - w.circle.xy) * float2(w.circle.w, 1.0);
        float r = length(q);
        if (r < w.circle.z) discard_fragment();
        // Painted steel in the cabin's light: a soft pool from the upper left, darker into the corners, and a shadow
        // the ring throws on the wall around it.
        float2 lp = in.ndc * float2(w.circle.w, 1.0) - float2(-0.9, 0.8);
        float pool = 0.25 + 0.75 * exp(-dot(lp, lp) * 0.35);
        float shade = mix(0.55, 1.0, smoothstep(w.circle.z, w.circle.z + 0.06, r));
        float grain = 0.94 + 0.06 * vnoise3(float3(in.ndc * 40.0, 1.3));
        ColorDepth o;
        o.color = float4(float3(0.16, 0.17, 0.16) * w.light.rgb * pool * shade * grain, 1.0);
        o.depth = float4(0.01, 0, 0, 1);
        return o;
    }
    """
}
