/// Metal source for Snowbound Cabin Window: the view from inside a log cabin through a three-by-two window.
/// Outside: two snowy ridges in aerial haze with alpenglow, three rows of snow-laden pines, a far cabin whose
/// window lights at dusk with a ribbon of chimney smoke, a snow field that glints by the sun or moon, a frozen
/// creek mirroring the sky, the window's light on the snow at night, and drifts banked against the panes.
/// Inside: log walls and a thick sill lit by the fire (with a candle in a jar and a mug), and ember-amber keys.
/// The glass and frame are the Window Kit's. Built on SkyShaders.common.
/// Smooth rules: no ray marching, ≤ 3 noise octaves (the smoke), squares written out (no pow).
enum SnowboundCabinShaders {
    static let source = SkyShaders.common + """
    struct CabinU {
        float4 a;        // keys top (NDC y), aspect, horizon (NDC y), time
        float4 rect;     // glass NDC x0, y0, x1, y1
        float4 b;        // night 0…1, fire (setting × flicker), flare (after the limiter), flare warmth 0…1
        float4 c;        // far cabin light 0…1, smoke 0…1, wind 0…1, mist
        float4 d;        // frame width (NDC x), sill height (NDC y), quality (0 Smooth), sparkle scale
        float4 light;    // the outside light rgb (the scene's average), snow
        float4 fire;     // the fire's colour rgb, the candle's flicker 0…1
        float4 bars[19]; // the Window Kit's bars: lo, hi (window coordinates), kind (0 vertical, 1 horizontal)
    };

    constant float2 cabinQuad[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };

    float ch11(float x) { return fract(sin(x * 127.1 + 311.7) * 43758.5453); }
    float ch21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }
    float cvn1(float x) {
        float i = floor(x), f = fract(x);
        float u = f * f * (3.0 - 2.0 * f);
        return mix(ch11(i), ch11(i + 1.0), u);
    }
    float cvn2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(ch21(i), ch21(i + float2(1, 0)), u.x), mix(ch21(i + float2(0, 1)), ch21(i + float2(1, 1)), u.x), u.y);
    }
    // Sharp-crested ridges: folded value noise, two octaves.
    float ridge(float x, float seed) {
        float a = 1.0 - abs(2.0 * cvn1(x + seed) - 1.0);
        float b = 1.0 - abs(2.0 * cvn1(x * 2.3 + seed * 1.7) - 1.0);
        return a * 0.72 + b * 0.28;
    }

    // The pane around a window point and whether it's on a bar (as the Window Kit lays them out).
    float4 cabinPane(float2 w, constant CabinU& c, thread bool& onBar) {
        float4 p = float4(0, 0, 1, 1);
        onBar = false;
        for (int i = 0; i < 19; i++) {
            float4 bar = c.bars[i];
            if (bar.y <= bar.x) continue;
            float v = bar.z < 0.5 ? w.x : w.y;
            if (v >= bar.x && v <= bar.y) onBar = true;
            if (bar.z < 0.5) {
                if (bar.y <= w.x) p.x = max(p.x, bar.y);
                if (bar.x >= w.x) p.z = min(p.z, bar.x);
            } else {
                if (bar.y <= w.y) p.y = max(p.y, bar.y);
                if (bar.x >= w.y) p.w = min(p.w, bar.x);
            }
        }
        return p;
    }

    // A row of snowy pines: coverage (soft-edged) and, through `snow`, how much of the hit is snow on the boughs.
    float pines(float sx, float sy, float base, float height, float density, float seed, thread float& snow) {
        float cell = floor(sx * density + seed);
        float hit = 0.0;
        snow = 0.0;
        for (int k = -1; k <= 1; k++) {
            float id = cell + float(k);
            float r = ch11(id * 1.37 + seed);
            float cx = (id + 0.5 + (r - 0.5) * 0.6 - seed) / density;
            float ht = height * (0.55 + 0.6 * ch11(id * 2.11 + seed * 3.0));
            float t = (sy - base) / ht;
            if (t < -0.1 || t > 1.0) continue;
            float tier = fract(t * 5.0 + r);
            float w = (1.0 - t) * 0.42 / density * (0.62 + 0.38 * (1.0 - tier)) + 0.002;
            float dx = abs(sx - cx);
            float inTree = 1.0 - smoothstep(w - 0.0015, w + 0.0015, dx);
            if (t < 0.06) inTree = max(inTree, 1.0 - smoothstep(0.0025, 0.004, dx));
            if (inTree > hit) {
                hit = inTree;
                float s = smoothstep(0.5, 0.85, tier) * smoothstep(0.15, 0.85, dx / max(w, 1e-4)) + smoothstep(0.84, 0.95, t);
                snow = saturate(s) * (0.55 + 0.45 * ch11(id * 5.3 + seed));
            }
        }
        return hit;
    }

    struct CabinOut { float4 pos [[position]]; float2 ndc; };

    vertex CabinOut cabin_glass_vertex(uint vid [[vertex_id]], constant CabinU& c [[buffer(1)]]) {
        float2 p = mix(c.rect.xy, c.rect.zw, cabinQuad[vid]);
        CabinOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    vertex CabinOut cabin_full_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        CabinOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // ---------------------------------------------------------------- outside the window
    fragment ColorDepth cabin_scene_fragment(CabinOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant CabinU& c [[buffer(1)]]) {
        float2 ndc = in.ndc;
        float aspect = c.a.y, horizon = c.a.z, time = c.a.w;
        float sx = ndc.x * aspect, sy = ndc.y;
        float night = c.b.x, fire = c.b.y, mist = c.c.w, sparkle = c.d.w;
        float3 d = normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
        float sunAlt = u.sun.w;
        float moonAlt = toDeg(asin(clamp(u.moon.z, -1.0, 1.0)));
        float cloud = u.horizon.w;
        float sunUp = smoothstep(-3.0, 6.0, sunAlt) * (1.0 - 0.75 * cloud);
        float moonUp = smoothstep(-2.0, 6.0, moonAlt) * u.moonInfo.x * (1.0 - 0.7 * cloud);
        float3 sunCol = mix(float3(1.0, 0.5, 0.28), float3(1.0, 0.95, 0.88), smoothstep(0.0, 25.0, sunAlt)) * 2.0 * sunUp;
        float3 moonCol = float3(0.55, 0.63, 0.82) * 0.32 * moonUp;
        float3 skyAmb = u.zenith.rgb * 0.55 + u.horizon.rgb * 0.45;
        float3 haze = u.horizon.rgb;
        // Light directions in camera space (x right, y up, z ahead).
        float3 Ls = float3(dot(u.sun.xyz, u.right.xyz), dot(u.sun.xyz, u.up.xyz), dot(u.sun.xyz, u.forward.xyz));
        float3 Lm = float3(dot(u.moon.xyz, u.right.xyz), dot(u.moon.xyz, u.up.xyz), dot(u.moon.xyz, u.forward.xyz));
        float3 fireCol = c.fire.rgb;
        float2 win = (ndc - c.rect.xy) / max(c.rect.zw - c.rect.xy, float2(1e-5));
        float glassBottom = c.rect.y;

        // ---- drifts banked against the panes (nearest of all)
        bool onBar;
        float4 pane = cabinPane(win, c, onBar);
        {
            float pu = (win.x - pane.x) / max(pane.z - pane.x, 1e-4);
            float ph = (win.y - pane.y) / max(pane.w - pane.y, 1e-4);
            float corner = max(max(0.0, 1.0 - pu / 0.32), max(0.0, 1.0 - (1.0 - pu) / 0.32));
            bool lowest = pane.y < 0.01;
            float profile = lowest ? 0.045 + 0.2 * corner * corner + 0.03 * cvn1(pu * 9.0 + pane.x * 31.0)
                                   : 0.012 + 0.07 * corner * corner + 0.01 * cvn1(pu * 11.0 + pane.y * 17.0);
            if (!onBar && ph < profile) {
                float top = saturate((profile - ph) / 0.05);
                float3 snowLit = skyAmb * 1.05 + sunCol * 0.5 * saturate(Ls.y + 0.3) + moonCol * 0.8 + fireCol * fire * 0.22 * night;
                float3 col = float3(0.92, 0.95, 1.0) * snowLit * mix(1.15, 0.78, top);
                col = mix(col, col * float3(0.75, 0.85, 1.1), smoothstep(0.4, 1.0, top) * 0.5);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.1, 0, 0, 1); return o;
            }
        }

        // ---- the ground: the snow field from the window down to the forest's edge
        float groundTop = horizon - 0.012 + 0.006 * sin(sx * 3.1);
        if (sy < groundTop) {
            float t = saturate((groundTop - sy) / max(groundTop - glassBottom, 1e-3));   // 0 far … 1 near
            float n = cvn2(float2(sx * 5.0, sy * 26.0 / (0.25 + t))) * 0.65 + cvn2(float2(sx * 13.0, sy * 61.0 / (0.25 + t)) + 3.7) * 0.35;
            float3 snowLit = skyAmb * 1.05 + sunCol * saturate(Ls.y * 0.85 + 0.15 + (n - 0.5) * 0.4)
                           + moonCol * saturate(Lm.y * 0.85 + 0.25);
            float3 col = float3(0.92, 0.95, 1.0) * snowLit;
            col = mix(col, col * float3(0.72, 0.84, 1.12), (1.0 - n) * 0.35);      // blue in the dips
            // Glints: a facet per 2 px, catching the sun or moon when it's tilted just right.
            if (t > 0.05) {
                float2 cell = floor(in.pos.xy * 0.5);
                float3 h = hash33(float3(cell, 1.0));
                float3 nf = normalize(float3((h.x - 0.5) * 0.7, 1.0, (h.y - 0.5) * 0.7));
                float3 V = -normalize(float3(ndc.x * u.right.w, ndc.y * u.up.w, 1.0));
                float tw = 0.65 + 0.35 * sin(time * (1.5 + 3.0 * h.z) + h.z * 40.0);
                float gs = smoothstep(0.9965, 1.0, dot(nf, normalize(Ls + V))) * sunUp;
                float gm = smoothstep(0.997, 1.0, dot(nf, normalize(Lm + V))) * moonUp;
                col += (float3(1.0, 0.95, 0.85) * gs * 7.0 + float3(0.75, 0.82, 1.0) * gm * 3.0) * tw * sparkle * smoothstep(0.05, 0.3, t);
            }
            // The frozen creek, winding across the field and mirroring the sky.
            float yc = glassBottom + (groundTop - glassBottom) * (0.48 + 0.13 * sin(sx * 2.1 + 0.7) + 0.06 * sin(sx * 5.3 + 2.0));
            float hw = 0.004 + 0.028 * t;
            float off = abs(sy - yc);
            if (off < hw && d.z < 0.0) {
                float3 r = float3(d.x, d.y, -d.z);
                float moonMask = 0.0;
                float3 ice = skyRadiance(r, u, moonMask) * 0.5 + float3(0.5, 0.64, 0.76) * skyAmb * 0.35;
                float crack = 1.0 - smoothstep(0.0, 0.035, abs(cvn2(float2(sx * 38.0, sy * 140.0)) - 0.5));
                ice *= 1.0 - 0.3 * crack;
                float bank = smoothstep(hw * 0.55, hw, off);
                col = mix(ice, col * 1.08, bank);
            }
            // At night the window's light falls on the snow below it, with the bars' shadows.
            float poolH = 0.2 * (groundTop - glassBottom);
            float pw = (sy - glassBottom) / max(poolH, 1e-3);
            if (night > 0.01 && pw < 1.0) {
                float pu = 0.5 + (win.x - 0.5) / (0.9 + 0.45 * pw);
                bool poolBar;
                cabinPane(float2(pu, pw), c, poolBar);
                float inside = (poolBar ? 0.0 : 1.0) * smoothstep(0.0, 0.06, pu) * smoothstep(1.0, 0.94, pu);
                col += fireCol * fire * 0.55 * night * inside * (1.0 - 0.6 * pw) * float3(1.0, 0.85, 0.7);
            }
            col = mix(col, haze * 1.05, (1.0 - t) * (0.12 + 0.4 * mist));
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.3 + 0.4 * (1.0 - t), 0, 0, 1); return o;
        }

        // ---- the far cabin, its window and its smoke (on the middle row of pines)
        float cabX = 0.38, cabBase = horizon - 0.002, cabW = 0.05, cabH = 0.022;
        float farLight = c.c.x;
        float3 snowAmb = skyAmb * 1.05 + sunCol * saturate(Ls.y + 0.2) * 0.8 + moonCol;

        // ---- pines, nearest row first
        float s3, s2, s1;
        float p3 = pines(sx, sy, groundTop - 0.004, 0.115, 9.0, 7.31, s3);
        if (p3 > 0.5) {
            float3 col = mix(float3(0.018, 0.03, 0.03) * (skyAmb + fireCol * fire * 0.2 * night), float3(0.92, 0.95, 1.0) * snowAmb, s3);
            col = mix(col, haze, 0.1 + 0.3 * mist);
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.55, 0, 0, 1); return o;
        }
        // The far cabin sits in front of the middle row.
        {
            float cx = sx - cabX, cy = sy - cabBase;
            float roof = cabH + 0.016 * (1.0 - abs(cx) / (cabW * 0.62));
            bool body = abs(cx) < cabW * 0.5 && cy > 0.0 && cy < cabH;
            bool roofHit = abs(cx) < cabW * 0.62 && cy >= cabH && cy < roof;
            bool chimney = cx > -cabW * 0.32 && cx < -cabW * 0.2 && cy >= cabH && cy < cabH + 0.022;
            if (body || roofHit || chimney) {
                float3 col = float3(0.05, 0.035, 0.03) * (skyAmb * 1.2 + sunCol * 0.3);
                if (roofHit) col = float3(0.92, 0.95, 1.0) * snowAmb * (0.8 + 0.2 * saturate((cy - cabH) / 0.016));
                if (body && abs(cx - 0.008) < 0.006 && cy > cabH * 0.35 && cy < cabH * 0.75) {
                    float3 lamp = float3(1.0, 0.68, 0.32) * 3.0 * farLight;
                    col = mix(col, lamp + float3(0.04, 0.035, 0.03), farLight > 0.01 ? 1.0 : 0.0);
                }
                col = mix(col, haze, 0.2 + 0.3 * mist);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.65, 0, 0, 1); return o;
            }
        }
        float p2 = pines(sx, sy, horizon - 0.004, 0.075, 15.0, 3.17, s2);
        // The far cabin's window glows faintly into the trees around it at night.
        float2 glowD = float2(sx - cabX - 0.008, sy - cabBase - cabH * 0.55);
        float cabinGlow = farLight * exp(-dot(glowD, glowD) * 900.0) * 0.35;
        if (p2 > 0.5) {
            float3 col = mix(float3(0.02, 0.035, 0.035) * skyAmb, float3(0.9, 0.94, 1.0) * snowAmb * 0.9, s2);
            col = mix(col, haze * 0.95, 0.28 + 0.35 * mist) + float3(1.0, 0.65, 0.3) * cabinGlow;
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.7, 0, 0, 1); return o;
        }
        float p1 = pines(sx, sy, horizon + 0.004, 0.045, 24.0, 1.93, s1);
        float3 behind = float3(0);
        float behindA = 0.0;
        float behindDepth = 1.0;
        if (p1 > 0.5) {
            float3 col = mix(float3(0.03, 0.045, 0.05) * skyAmb, float3(0.88, 0.92, 1.0) * snowAmb * 0.8, s1);
            behind = mix(col, haze * 0.95, 0.48 + 0.3 * mist);
            behindA = 1.0; behindDepth = 0.78;
        } else {
            // ---- the mountains: a near ridge, then a far one in deeper haze
            for (int k = 0; k < 2; k++) {
                float seed = k == 0 ? 7.7 : 3.1;
                float freq = k == 0 ? 1.9 : 1.15;
                float h0 = k == 0 ? 0.03 : 0.1;
                float amp = k == 0 ? 0.1 : 0.17;
                float top = horizon + h0 + amp * ridge(sx * freq, seed);
                if (sy < top) {
                    float slope = (ridge((sx + 0.01) * freq, seed) - ridge((sx - 0.01) * freq, seed)) / 0.02 * amp;
                    float3 n = normalize(float3(-slope, 1.0, 0.45));
                    float heightFrac = saturate((sy - horizon) / max(top - horizon, 1e-3));
                    float rock = smoothstep(0.55, 0.75, abs(slope)) * smoothstep(0.45, 0.6, cvn2(float2(sx * 14.0, sy * 40.0)));
                    float3 albedo = mix(float3(0.9, 0.93, 1.0), float3(0.18, 0.17, 0.18), rock * 0.8);
                    float3 col = albedo * (skyAmb * 0.85 + sunCol * saturate(dot(n, Ls)) + moonCol * saturate(dot(n, Lm)) * 1.4);
                    // Alpenglow: the peaks catch the low sun pink-orange, from just before sunrise to a little after.
                    float alpen = smoothstep(-2.5, -0.5, sunAlt) * (1.0 - smoothstep(5.0, 8.0, sunAlt)) * (1.0 - 0.6 * cloud);
                    col += float3(1.0, 0.42, 0.32) * alpen * 0.75 * smoothstep(0.25, 0.85, heightFrac) * saturate(dot(n, Ls) + 0.6);
                    col = mix(col, haze, (k == 0 ? 0.3 : 0.52) + 0.35 * mist);
                    behind = col; behindA = 1.0; behindDepth = k == 0 ? 0.85 : 0.92;
                    break;
                }
            }
        }
        // ---- the far cabin's chimney smoke, leaning with the wind, over whatever is behind it
        float smoke = 0.0;
        {
            float chimX = cabX - cabW * 0.26, chimTop = cabBase + cabH + 0.022;
            float rise = sy - chimTop;
            if (rise > 0.0 && rise < 0.24) {
                float centre = chimX + rise * (0.15 + 0.9 * c.c.z) + 0.012 * sin(rise * 22.0 - time * 0.7);
                float width = 0.003 + rise * 0.14;
                float q = (sx - centre) / width;
                float body = exp(-q * q);
                float n = cvn2(float2(sx * 34.0, sy * 34.0 - time * 0.5)) * 0.55 + cvn2(float2(sx * 70.0, sy * 70.0 - time * 0.9) + 5.1) * 0.3
                        + cvn2(float2(sx * 140.0, sy * 140.0 - time * 1.4) + 9.3) * 0.15;
                smoke = body * smoothstep(0.25, 0.75, n) * (1.0 - smoothstep(0.06, 0.24, rise)) * smoothstep(0.0, 0.01, rise) * c.c.y * 0.75;
            }
        }
        float3 smokeCol = skyAmb * 1.1 + sunCol * 0.25 + moonCol * 0.6;
        float3 col = behind * behindA * (1.0 - smoke) + smokeCol * smoke;
        float a = 1.0 - (1.0 - behindA) * (1.0 - smoke);
        // The cabin's glow also hazes the air (and sky) around it.
        col += float3(1.0, 0.65, 0.3) * cabinGlow * 0.6;
        if (a < 0.003 && cabinGlow < 0.003) discard_fragment();
        ColorDepth o; o.color = float4(col, max(a, 0.0)); o.depth = float4(behindA > 0.5 ? behindDepth : 0.9, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- high notes: flakes by the glass catch the light
    struct Spark { float4 a; };   // x, y (NDC), size (NDC x), brightness
    struct SparkOut { float4 pos [[position]]; float2 uv; float bright; };
    vertex SparkOut cabin_spark_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Spark* ss [[buffer(0)]],
                                       constant CabinU& c [[buffer(1)]]) {
        float2 q = cabinQuad[vid] * 2.0 - 1.0;
        Spark s = ss[iid];
        SparkOut o;
        o.uv = q;
        o.pos = float4(s.a.xy + q * float2(s.a.z, s.a.z * c.a.y), 0, 1);
        o.bright = s.a.w;
        return o;
    }
    fragment float4 cabin_spark_fragment(SparkOut in [[stage_in]], constant CabinU& c [[buffer(1)]]) {
        float2 p = in.uv;
        float r = length(p);
        float rays = exp(-abs(p.x) * 18.0) * exp(-abs(p.y) * 2.2) + exp(-abs(p.y) * 18.0) * exp(-abs(p.x) * 2.2);
        float core = exp(-r * r * 30.0);
        float a = saturate(rays * 0.6 + core) * (1.0 - smoothstep(0.7, 1.0, r)) * in.bright;
        float3 col = mix(float3(0.85, 0.9, 1.0), c.fire.rgb, 0.35) * 2.2;
        return float4(col * a, 0.0);
    }

    // ---------------------------------------------------------------- the room: log walls and the sill
    fragment ColorDepth cabin_room_fragment(CabinOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant CabinU& c [[buffer(1)]]) {
        float2 p = in.ndc;
        float aspect = c.a.y, time = c.a.w;
        float fw = c.d.x, fh = c.d.x * aspect;
        float4 outer = c.rect + float4(-fw, -fh, fw, fh);
        float sx = p.x * aspect, sy = p.y;
        // The candle jar and the mug stand on the sill in front of the window's lower frame; the rest of the
        // window belongs to the glass and frame.
        float sillTopY = outer.y;
        float2 jarP = float2(sx - (outer.x + 0.17) * aspect, sy - (sillTopY - 0.012));
        float2 mugP = float2(sx - (outer.z - 0.2) * aspect, sy - (sillTopY - 0.014));
        bool overWindow = p.x > outer.x && p.x < outer.z && p.y > outer.y && p.y < outer.w;
        bool mayHit = (abs(jarP.x) < 0.034 && jarP.y > 0.0 && jarP.y < 0.1) || (mugP.x > -0.032 && mugP.x < 0.058 && mugP.y > 0.0 && mugP.y < 0.06);
        if (overWindow && !mayHit) discard_fragment();
        float night = c.b.x, fire = c.b.y, flare = c.b.z;
        float3 fireCol = c.fire.rgb;
        // Firelight from low and to the left (off screen), flickering; chords flare it.
        float2 firePos = float2(-1.3 * aspect, -1.2);
        float2 fv = float2(sx, sy) - firePos;
        float3 fireLight = fireCol * fire * (1.0 + 0.8 * flare) * (1.5 / (1.0 + dot(fv, fv) * 0.55));
        // Daylight or moonlight spilling in around the window.
        float2 nearest = clamp(p, outer.xy, outer.zw);
        float wd = length((p - nearest) * float2(aspect, 1.0));
        float3 winLight = c.light.rgb * 0.5 * exp(-wd * 3.5);
        float3 ambient = c.light.rgb * 0.03 + fireCol * fire * 0.025;

        // The candle in its jar, on the sill to the left, and its glow.
        float sillTop = outer.y, sillH = c.d.y;
        float candleX = (outer.x + 0.17) * aspect, candleBase = sillTop - 0.012;
        float flick = c.fire.w;
        float2 flameC = float2(candleX + 0.002 * sin(time * 9.0), candleBase + 0.068 + 0.004 * flick);
        float2 fd = float2(sx, sy) - flameC;
        float3 candleLight = float3(1.0, 0.62, 0.28) * (0.75 + 0.35 * flick) * (0.08 / (0.004 + dot(fd, fd) * 3.0));

        float3 col;
        float depth = 0.05;
        float sillX0 = (outer.x - 0.06) * aspect, sillX1 = (outer.z + 0.06) * aspect;
        bool onSill = sy <= sillTop && sy > sillTop - sillH && sx > sillX0 && sx < sillX1;
        if (onSill) {
            // A thick plank: a lit top face, a darker front face, varnished grain.
            float topFace = sillTop - 0.035;
            float grain = cvn2(float2(sx * 2.5, sy * 60.0)) * 0.6 + cvn2(float2(sx * 9.0, sy * 140.0) + 2.3) * 0.4;
            float3 albedo = mix(float3(0.26, 0.15, 0.08), float3(0.45, 0.29, 0.16), grain);
            float lit = sy > topFace ? 1.0 : 0.45;
            col = albedo * (fireLight * lit + winLight * (sy > topFace ? 1.6 : 0.4) + ambient + candleLight * lit);
            if (sy > topFace && sy < topFace + 0.004) col *= 1.25;   // the front edge catches the light
        } else {
            // Log walls: rounded logs with dark chinking between them, lit by the fire and the window.
            float logH = 0.13;
            float row = floor((sy + 0.03) / logH);
            float v = fract((sy + 0.03) / logH);
            float across = v * 2.0 - 1.0;
            float nz = sqrt(saturate(1.0 - across * across));
            float3 n = float3(0.0, across, nz);
            float diff = saturate(dot(n, normalize(float3(-0.4, -0.55, 0.75))));
            float grain = cvn2(float2(sx * 3.0, row * 7.1 + across * 2.0)) * 0.6 + cvn2(float2(sx * 11.0, row * 3.3 + v * 4.0)) * 0.4;
            float knot = smoothstep(0.92, 0.97, cvn2(float2(sx * 6.0 + row * 13.0, row * 1.7)));
            float3 albedo = mix(float3(0.17, 0.095, 0.05), float3(0.32, 0.19, 0.1), grain) * (1.0 - 0.5 * knot);
            float chink = smoothstep(0.86, 0.97, abs(across));
            albedo = mix(albedo, float3(0.24, 0.22, 0.19), chink * 0.8);
            col = albedo * (fireLight * (0.3 + 0.7 * diff) + winLight * (0.5 + 0.5 * nz) + ambient) * (1.0 - 0.45 * chink);
            col += albedo * candleLight * 0.6;
            depth = 0.06;
        }

        // On the sill: the candle jar and a mug.
        float jarW = 0.034, jarH = 0.085;
        float2 jp = float2(sx - candleX, sy - candleBase);
        if (abs(jp.x) < jarW && jp.y > 0.0 && jp.y < jarH) {
            float edge = smoothstep(jarW - 0.005, jarW, abs(jp.x));
            float3 glass = (winLight + fireLight * 0.4) * 0.25 + float3(1.0, 0.62, 0.28) * (0.35 + 0.2 * flick) * (1.0 - jp.y / jarH);
            bool wax = abs(jp.x) < jarW - 0.008 && jp.y < 0.045;
            float3 waxCol = float3(0.9, 0.82, 0.68) * (float3(1.0, 0.62, 0.28) * (0.7 + 0.3 * flick) * (0.4 + jp.y / 0.045) + ambient);
            col = wax ? waxCol : mix(col, col * 0.6 + glass, 0.55) + float3(0.6, 0.62, 0.65) * edge * 0.25 * (0.3 + night);
            if (jp.y > jarH - 0.006) col += float3(0.5) * 0.15;   // the rim
        }
        // The flame: a small teardrop, bright core.
        float2 fq = float2(fd.x / 0.007, (fd.y + 0.006) / (0.018 + 0.006 * flick));
        float flame = 1.0 - smoothstep(0.6, 1.0, length(float2(fq.x * (1.0 + 0.6 * saturate(fq.y)), fq.y)));
        col = mix(col, float3(1.0, 0.55, 0.15) * 4.0 + float3(1.0, 0.95, 0.75) * 5.0 * smoothstep(0.4, 1.0, flame), flame);

        float mugX = (outer.z - 0.2) * aspect, mugBase = sillTop - 0.014;
        float2 mp = float2(sx - mugX, sy - mugBase);
        float mugW = 0.032, mugH = 0.06;
        float ring = abs(length(float2(mp.x - mugW - 0.004, mp.y - mugH * 0.5)) - 0.016);
        bool handle = ring < 0.005 && mp.x > mugW - 0.002;
        bool mugBody = abs(mp.x) < mugW && mp.y > 0.0 && mp.y < mugH;
        if (mugBody || handle) {
            float shade = mugBody ? sqrt(saturate(1.0 - (mp.x / mugW) * (mp.x / mugW))) : 0.6;
            float3 glaze = float3(0.62, 0.2, 0.16);
            col = glaze * (fireLight * (0.35 + 0.65 * shade * saturate(0.5 - mp.x / mugW)) + winLight * 0.8 + ambient + candleLight * 0.5);
            col += float3(1.0) * smoothstep(0.85, 1.0, shade) * 0.05 * (0.3 + night);
            if (mugBody && mp.y > mugH - 0.005) col *= 0.5;
        }
        // Soft contact shadows on the sill.
        if (onSill) {
            float sj = exp(-(jp.x * jp.x) / 0.002) * exp(-max(0.0, -jp.y) * 60.0) * step(jp.y, 0.0);
            float sm = exp(-(mp.x * mp.x) / 0.002) * exp(-max(0.0, -mp.y) * 60.0) * step(mp.y, 0.0);
            col *= 1.0 - 0.4 * saturate(sm) - 0.2 * saturate(sj);
        }
        // Over the window only the jar, its flame and the mug are drawn.
        bool objectHit = (abs(jp.x) < jarW && jp.y > 0.0 && jp.y < jarH) || mugBody || handle || flame > 0.05;
        if (overWindow && !objectHit) discard_fragment();
        ColorDepth o; o.color = float4(col, 1); o.depth = float4(depth, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- keys: ember amber where you play
    struct CabinKey { float4 rect; float4 info; };   // rect NDC; info: black, glow, pressed, light
    struct CabinKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex CabinKeyOut cabin_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant CabinKey* keys [[buffer(0)]]) {
        CabinKey k = keys[iid];
        CabinKeyOut o;
        o.uv = cabinQuad[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth cabin_keys_fragment(CabinKeyOut in [[stage_in]], constant CabinU& c [[buffer(1)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.012, 0.009, 0.008) : float3(0.11, 0.085, 0.065);
        float y2 = in.uv.y * in.uv.y;
        float y6 = y2 * y2 * y2;
        float sheen = y6 * (black ? 0.05 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 ember = float3(1.0, 0.42, 0.12);
        float3 col = base * (c.fire.rgb * c.b.y * 0.6 + light) + float3(0.9, 0.75, 0.6) * sheen * (0.3 + 0.6 * light)
                   + ember * glow * (1.8 * (0.3 + 0.7 * in.uv.y));
        col *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
