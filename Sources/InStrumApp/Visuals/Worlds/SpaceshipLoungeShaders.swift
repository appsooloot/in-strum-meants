/// Metal source for the Spaceship Lounge: space through the window (stars, Milky Way, Earth with clouds,
/// city lights and an atmosphere rim, the Moon in its phase, sun glare), the lounge's frame and a console keyboard.
/// Built on SkyShaders.common (noise, starField, milkyWay). Smooth rules: no ray marching, ≤ 3 octaves (2 on Smooth).
enum SpaceshipLoungeShaders {
    static let source = SkyShaders.common + """
    // p-space: x scaled by the aspect ratio, y as NDC.
    struct LoungeU {
        float4 a;          // aspect, time, keys top (NDC y), interior glow 0…1
        float4 earth;      // centre (p-space xy), radius, octaves
        float4 east;       // Earth-fixed basis under the window: east (xyz), pixel angle
        float4 north;      // north (xyz), moonlit 0…1
        float4 up;         // the point below (xyz), unused
        float4 sun;        // sun direction (Earth-fixed xyz), unused
        float4 glare;      // limb sunrise: position (p-space xy), size, strength
        float4 veil;       // day-side glare from the window's edge: position (xy), size, strength
        float4 moon;       // position (p-space xy), radius, phase 0…1
        float4 moonLight;  // sun's direction on screen (xy), lit fraction, unused
        float4 window;     // half width (p-space), bottom (NDC), top (NDC), corner radius
        float4 eq0, eq1, eq2;  // view → equatorial (star field)
    };
    struct LoungeOut { float4 pos [[position]]; float2 ndc; };

    vertex LoungeOut lounge_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        LoungeOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float sdRoundBox(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // Signed distance to the glass (negative inside a pane): the window minus two struts.
    float glassDistance(float2 p, constant LoungeU& u) {
        float bottom = u.window.y, top = u.window.z;
        float2 c = float2(0.0, 0.5 * (bottom + top));
        float d = sdRoundBox(p - c, float2(u.window.x, 0.5 * (top - bottom)), u.window.w);
        float strutHalf = 0.018;
        for (int i = -1; i <= 1; i += 2) {
            float sx = float(i) * u.window.x * 0.34;
            d = max(d, strutHalf - abs(p.x - sx));
        }
        return d;
    }

    float3 earthColour(float3 n, constant LoungeU& u, int octaves, float time, float moonlit) {
        float3 S = u.sun.xyz;
        float c = fbm3(n * 1.9 + 3.1, octaves);
        float land = smoothstep(0.53, 0.57, c);
        float shallow = smoothstep(0.46, 0.53, c) * (1.0 - land);
        float lat = abs(n.z);
        float dry = smoothstep(0.45, 0.75, vnoise3(n * 3.0 + 7.0)) * (1.0 - smoothstep(0.35, 0.6, lat));
        float3 ocean = mix(float3(0.004, 0.016, 0.055), float3(0.01, 0.05, 0.09), shallow);
        float3 ground = mix(float3(0.03, 0.055, 0.022), float3(0.17, 0.13, 0.075), dry);
        float3 surface = mix(ocean, ground, land);
        float ice = smoothstep(0.82, 0.88, lat + 0.04 * vnoise3(n * 8.0));
        surface = mix(surface, float3(0.75, 0.8, 0.86), ice);
        float cl = fbm3(n * 3.2 + float3(time * 0.004, 0.0, time * 0.002), octaves);
        float cloud = smoothstep(0.5, 0.78, cl) * 0.9;

        float ndl = dot(n, S);
        float sunlit = max(ndl, 0.0);
        float3 day = mix(surface, float3(0.9, 0.92, 0.95), cloud) * sunlit * 2.6;
        float twilight = exp(-abs(ndl) / 0.07);
        day += float3(0.55, 0.22, 0.07) * twilight * (0.12 + 0.3 * cloud);

        // Night: city lights on the land, softened by cloud; moonlight greys the clouds.
        float dark = smoothstep(0.05, -0.12, ndl);
        float cities = land * (1.0 - ice) * (pow(vnoise3(n * 45.0), 6.0) * 2.5 + pow(vnoise3(n * 140.0), 12.0) * 6.0);
        float3 night = float3(1.0, 0.66, 0.3) * cities * 0.35 * (1.0 - 0.75 * cloud)
                     + mix(surface * 0.12, float3(0.16, 0.18, 0.24), cloud) * moonlit * 0.6;
        return day + night * dark;
    }

    fragment ColorDepth lounge_space_fragment(LoungeOut in [[stage_in]], constant LoungeU& u [[buffer(0)]]) {
        float2 ndc = in.ndc;
        float aspect = u.a.x, time = u.a.y;
        float2 p = float2(ndc.x * aspect, ndc.y);
        int octaves = int(u.earth.w + 0.5);
        ColorDepth out;
        out.depth = float4(1.0, 0, 0, 1);

        // Deep space: stars and the Milky Way, no atmosphere.
        const float tanV = 0.7;
        float3 ray = normalize(float3(ndc.x * aspect * tanV, ndc.y * tanV, 1.0));
        float3 v = float3x3(u.eq0.xyz, u.eq1.xyz, u.eq2.xyz) * ray;
        float3 col = float3(0.0012, 0.0015, 0.0028);
        col += starField(v, u.east.w, time, 1.0) * 1.2 + milkyWay(v, octaves, 1.0) * 2.0;

        // The Moon in its phase, lit from the sun's side.
        float2 mq = (p - u.moon.xy) / u.moon.z;
        float mr2 = dot(mq, mq);
        if (mr2 < 1.0) {
            float3 n = float3(mq, sqrt(1.0 - mr2));
            float E = 6.2831853 * u.moon.w;
            float3 L = float3(0, 0, -1) * cos(E) + float3(u.moonLight.xy, 0) * sin(E);
            float lit = smoothstep(-0.03, 0.06, dot(n, L));
            float maria = 0.78 + 0.22 * fbm3(n * 3.0 + 11.0, 2);
            float limb = 0.75 + 0.25 * n.z;
            float edge = smoothstep(1.0, 0.9, mr2);
            col = mix(col, float3(1.0, 0.97, 0.9) * 1.5 * maria * limb * (lit + 0.015), edge);
        }

        // Earth: an orthographic sphere turning beneath the window.
        float2 eq = (p - u.earth.xy) / u.earth.z;
        float er = length(eq);
        float3 S = u.sun.xyz;
        float moonlit = u.north.w;
        if (er < 1.0) {
            float z = sqrt(1.0 - er * er);
            float3 n = normalize(u.east.xyz * eq.x + u.north.xyz * eq.y + u.up.xyz * z);
            col = earthColour(n, u, octaves, time, moonlit);
            // The atmosphere seen edge-on: blue where it's day, a sunset band at the terminator.
            float limbN = pow(1.0 - z, 3.0);
            float ndl = dot(n, S);
            col += float3(0.18, 0.4, 1.0) * limbN * (0.04 + 1.4 * smoothstep(-0.25, 0.4, ndl));
            col += float3(1.0, 0.45, 0.15) * limbN * exp(-abs(ndl - 0.02) / 0.08) * 0.8;
            out.depth = float4(0.9, 0, 0, 1);
        } else {
            float3 ln = normalize(u.east.xyz * eq.x + u.north.xyz * eq.y);
            float ndl = dot(ln, S);
            float h = (er - 1.0) * u.earth.z;
            float glow = exp(-h / 0.022), haze = exp(-h / 0.09);
            col += float3(0.25, 0.5, 1.0) * (glow * 0.9 + haze * 0.12) * (0.03 + 1.3 * smoothstep(-0.3, 0.35, ndl));
            col += float3(1.0, 0.42, 0.12) * glow * exp(-abs(ndl - 0.03) / 0.09) * 1.1;
            col += float3(0.35, 0.9, 0.5) * exp(-abs(h - 0.012) / 0.004) * 0.025 * smoothstep(0.1, -0.2, ndl);   // airglow
        }

        // Sun glare: a sunrise on the limb, or the day side's light spilling in at the window's edge.
        float gd = length(p - u.glare.xy);
        float3 sunCol = float3(1.0, 0.93, 0.82);
        float core = exp(-gd / max(u.glare.z, 1e-3)) * (er > 1.0 ? 1.0 : 0.0);
        col += sunCol * u.glare.w * (core * 7.0 + exp(-gd / 0.14) * 0.5 + exp(-gd / 0.6) * 0.07);
        col += sunCol * u.glare.w * 0.3 * exp(-abs(p.y - u.glare.y) / 0.005) * exp(-abs(p.x - u.glare.x) / 0.9);
        float vd = length(p - u.veil.xy);
        col += float3(1.0, 0.9, 0.75) * u.veil.w * exp(-vd / max(u.veil.z, 1e-3));

        // Faint reflections on the glass: the lounge's warm glow low down, a soft diagonal sheen.
        float glow = u.a.w;
        float rise = ndc.y - u.window.y;
        col += float3(0.06, 0.035, 0.02) * glow * exp(-max(rise, 0.0) / 0.12) * 0.6;
        float sheen = smoothstep(0.12, 0.0, abs(fract((p.x + p.y * 0.6) * 0.35 + 0.2) - 0.5));
        col += float3(0.012, 0.014, 0.018) * sheen;
        out.color = float4(col, 1.0);
        return out;
    }

    // The lounge around the window: dark warm walls lit from below, bevelled window edges catching the light.
    fragment ColorDepth lounge_frame_fragment(LoungeOut in [[stage_in]], constant LoungeU& u [[buffer(0)]]) {
        float2 ndc = in.ndc;
        float aspect = u.a.x;
        float2 p = float2(ndc.x * aspect, ndc.y);
        float d = glassDistance(p, u);
        float px = 2.0 / 720.0;
        float cover = smoothstep(-px, px, d);
        if (cover < 0.004) discard_fragment();
        float glow = u.a.w, keysTop = u.a.z;
        float3 wall = float3(0.016, 0.011, 0.008);
        wall += float3(0.22, 0.12, 0.065) * glow * exp(-max(ndc.y - keysTop, 0.0) / 0.55);
        wall += float3(0.03, 0.02, 0.014) * glow * exp(-abs(ndc.x) * 0.8);
        // The bevel just outside the glass catches warm light below and cool earthlight above.
        float bevel = exp(-max(d, 0.0) / 0.012);
        float3 edge = mix(float3(0.12, 0.07, 0.04) * (0.4 + glow), float3(0.03, 0.05, 0.09), smoothstep(-0.2, 0.6, ndc.y));
        wall += edge * bevel * 0.5;
        // A soft shadow line where the wall meets the bevel, and corners in shade.
        wall *= 0.75 + 0.25 * smoothstep(0.012, 0.05, d);
        wall *= 0.7 + 0.3 * smoothstep(1.25, 0.6, abs(ndc.x)) ;
        ColorDepth o;
        o.color = float4(wall * cover, cover);
        o.depth = float4(0.08, 0, 0, 1);
        return o;
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, unused); console blue glow.
    struct KeyInstance { float4 rect; float4 info; };
    struct KeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex KeyOut lounge_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant KeyInstance* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        KeyInstance k = keys[iid];
        KeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth lounge_keys_fragment(KeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z;
        float3 base = black ? float3(0.005, 0.006, 0.009) : float3(0.03, 0.033, 0.04);
        float3 blue = float3(0.35, 0.6, 1.0);
        float sheen = pow(in.uv.y, 6.0) * (black ? 0.04 : 0.1) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 c = base + float3(0.9, 0.85, 0.8) * sheen * 0.5 + blue * glow * (1.6 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.08, 0, 0, 1);
        return o;
    }
    """
}
