/// Butterfly Garden: sky, sun and god-rays, foliage, meadow, blooms, butterflies,
/// pollen/petals/fireflies and keys. All procedural (no image files).
/// Scene space: x 0...1 across, y 0...1 up (above the keyboard), z depth 0 near ... 1 far.
enum ButterflyShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SceneU {
        float4 a;          // resolution.x, resolution.y, time, keyTop (0...1 of screen height)
        float4 sun;        // sunX, sunY (0...1 screen), rays, mist
        float4 skyTop;     // rgb, night (0/1)
        float4 skyHorizon; // rgb, foliage
        float4 air;        // breezeX, pollen, petals, fireflies
        float4 cam;        // zoom, camX, camY, parallax
        float4 look;       // iridescence, shimmer, trailGlow, keysShow
        float4 counts;     // pollenCount, petalCount, fireflyCount, exposureHint
        float4 keyGlow;    // rgb, finish index
    };

    struct ColorDepth { float4 color [[color(0)]]; float4 depth [[color(1)]]; };

    // ---------- helpers ----------
    float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
    float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }
    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + 17.0; a *= 0.5; }
        return v;
    }
    float3 hsv(float h, float s, float v) {
        float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return v * mix(float3(1.0), k, s);
    }
    // Scene (x, y, z) → clip space, with zoom, camera drift and parallax.
    float2 toClip(float3 p, constant SceneU& u) {
        float depthScale = 1.0 + (0.5 - p.z) * u.cam.w * 0.35;
        float sx = (p.x - 0.5) * depthScale * u.cam.x + 0.5 + u.cam.y * (1.0 - p.z);
        float keyTop = u.a.w;
        float sy = keyTop + p.y * (1.0 - keyTop);
        sy = (sy - 0.5) * u.cam.x + 0.5 + u.cam.z * (1.0 - p.z);
        return float2(sx * 2.0 - 1.0, sy * 2.0 - 1.0);
    }

    // ---------- sky, sun, god-rays, foliage, meadow (fullscreen) ----------
    struct SkyOut { float4 pos [[position]]; float2 uv; };
    vertex SkyOut sky_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        SkyOut o; o.pos = float4(p[vid], 0, 1); o.uv = (p[vid] + 1.0) * 0.5; return o;
    }

    float foliageMask(float2 uv, constant SceneU& u, float t) {
        float density = u.skyHorizon.w;
        float aspect = u.a.x / u.a.y;
        float2 q = float2(uv.x * aspect, uv.y);
        // distant tree line along the horizon
        float horizon = u.a.w + (1.0 - u.a.w) * 0.30;
        float line = horizon + 0.06 * density + 0.08 * fbm(float2(q.x * 3.0, 1.0)) * density;
        float back = smoothstep(line + 0.004, line - 0.004, uv.y) * step(u.a.w, uv.y);
        // overhanging canopy in the top corners, swaying gently
        float sway = 0.01 * sin(t * 0.6) + 0.02 * u.air.x * sin(t * 0.8 + uv.y * 4.0);
        float cornerL = fbm(float2(q.x * 4.0 + sway * 10.0, uv.y * 4.0)) - (uv.x + (1.0 - uv.y) * 0.9) * 1.1 + 0.35 + 0.25 * density;
        float cornerR = fbm(float2(q.x * 4.0 + 7.0 - sway * 10.0, uv.y * 4.0 + 3.0)) - ((1.0 - uv.x) + (1.0 - uv.y) * 0.9) * 1.1 + 0.35 + 0.25 * density;
        float canopy = smoothstep(0.0, 0.04, max(cornerL, cornerR));
        return clamp(max(back, canopy), 0.0, 1.0);
    }

    fragment ColorDepth sky_fragment(SkyOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float t = u.a.z;
        float aspect = u.a.x / u.a.y;
        float keyTop = u.a.w;
        float h = clamp((uv.y - keyTop) / (1.0 - keyTop), 0.0, 1.0);
        float3 col = mix(u.skyHorizon.rgb, u.skyTop.rgb, pow(h, 0.8));
        // soft clouds
        float clouds = fbm(float2(uv.x * aspect * 1.5 + t * 0.01, uv.y * 3.0));
        col = mix(col, col * 1.12 + 0.03, smoothstep(0.55, 0.85, clouds) * 0.5 * (1.0 - u.skyTop.w * 0.6));
        // sun or moon
        float2 sp = float2(u.sun.x, u.sun.y);
        float2 d = (uv - sp) * float2(aspect, 1.0);
        float r = length(d);
        float night = u.skyTop.w;
        float3 sunCol = mix(float3(1.0, 0.86, 0.6), float3(0.85, 0.9, 1.0), night);
        col += sunCol * (smoothstep(0.045, 0.035, r) * (night > 0.5 ? 1.2 : 3.0) + exp(-r * 9.0) * (night > 0.5 ? 0.15 : 0.6));
        // stars at night
        if (night > 0.5) {
            float2 g = floor(uv * float2(aspect, 1.0) * 120.0);
            float s = step(0.997, hash21(g)) * (0.5 + 0.5 * sin(t * 2.0 + hash21(g + 3.0) * 30.0));
            col += float3(s) * h;
        }
        // foliage silhouettes
        float leaves = foliageMask(uv, u, t);
        float3 leafCol = mix(float3(0.05, 0.09, 0.05), u.skyHorizon.rgb * 0.25, 0.35) * (1.0 - night * 0.6);
        // sun-lit rim on leaves
        leafCol += sunCol * 0.08 * exp(-r * 3.0) * (1.0 - night);
        col = mix(col, leafCol, leaves * 0.92);
        // god-rays: march from pixel toward the sun, collecting gaps between leaves
        float rays = 0.0;
        if (u.sun.z > 0.01) {
            float2 stepv = (sp - uv) / 24.0;
            float2 p = uv;
            float decay = 1.0;
            for (int i = 0; i < 24; i++) {
                p += stepv;
                rays += (1.0 - foliageMask(p, u, t)) * decay * 0.06;
                decay *= 0.94;
            }
            float streaks = 0.6 + 0.4 * fbm(float2(atan2(d.y, d.x) * 6.0, t * 0.05));
            rays *= streaks * exp(-r * 1.4);
        }
        col += sunCol * rays * u.sun.z * 1.4;
        // meadow
        float meadowTop = keyTop + (1.0 - keyTop) * 0.16;
        if (uv.y < meadowTop) {
            float mh = (meadowTop - uv.y) / (meadowTop - keyTop + 1e-4);
            float blades = fbm(float2(uv.x * aspect * 60.0, uv.y * 8.0)) * 0.6 + fbm(float2(uv.x * aspect * 14.0 + t * 0.05 * u.air.x, uv.y * 3.0)) * 0.4;
            float3 grass = mix(float3(0.18, 0.32, 0.12), float3(0.06, 0.14, 0.05), mh) * (0.7 + 0.5 * blades);
            grass = mix(grass, grass * u.skyHorizon.rgb * 1.6, 0.35) * (1.0 - night * 0.65);
            float edge = smoothstep(0.0, 0.02, meadowTop - uv.y + (blades - 0.5) * 0.03);
            col = mix(col, grass, edge);
        }
        // mist hugging the horizon
        float horizonY = keyTop + (1.0 - keyTop) * 0.3;
        col = mix(col, u.skyHorizon.rgb * 1.05 + 0.05, u.sun.w * exp(-abs(uv.y - horizonY) * 7.0) * 0.6);
        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(1.0, 0, 0, 1);
        return o;
    }

    // ---------- instanced sprites (butterflies, trails, blooms) ----------
    struct Sprite {
        float4 pos;    // x, y, z, size (fraction of screen height)
        float4 a;      // butterflies: hue, flapPhase, style, glow   | blooms: hue, openness, kind, seed
        float4 b;      // butterflies: opacity, landed, side, seed   | blooms: opacity, 0, 0, 0
    };
    struct SpriteOut { float4 pos [[position]]; float2 uv; float4 a; float4 b; float z; float extent; };

    // Butterflies use two instances per butterfly (left/right wing, b.z = -1/+1); blooms use b.z = 0.
    vertex SpriteOut sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant Sprite* sprites [[buffer(0)]], constant SceneU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Sprite s = sprites[iid];
        float2 q = c[vid];
        float aspect = u.a.x / u.a.y;
        float size = s.pos.w;
        float2 offset;
        float extent = 1.0;
        SpriteOut o;
        if (s.b.z != 0.0) {
            // wing: u outward 0..1, v -1..1; flap foreshortens the wing horizontally
            float side = s.b.z;
            float phase = s.a.y;
            float open = 0.18 + 0.82 * (0.5 + 0.5 * cos(phase * 6.28318));
            if (s.b.y > 0.5) { open = 0.12 + 0.1 * (0.5 + 0.5 * cos(phase * 6.28318)); }
            extent = open;
            float tilt = 0.18 * sin(u.a.z * 1.3 + s.b.w * 40.0);
            float2 local = float2(side * q.x * open * 1.1, (q.y * 2.0 - 1.0) * 0.95);
            local = float2(local.x * cos(tilt) - local.y * sin(tilt), local.x * sin(tilt) + local.y * cos(tilt));
            offset = local * size;
            o.uv = float2(q.x, q.y * 2.0 - 1.0);
        } else {
            offset = (q * 2.0 - 1.0) * size;
            o.uv = q * 2.0 - 1.0;
        }
        float2 clip = toClip(s.pos.xyz, u);
        o.pos = float4(clip + float2(offset.x / aspect, offset.y) * 2.0 * u.cam.x, 0, 1);
        o.a = s.a; o.b = s.b; o.z = s.pos.z; o.extent = extent;
        return o;
    }

    float ellipse(float2 p, float2 c, float2 r, float rot) {
        float2 d = p - c;
        d = float2(d.x * cos(rot) + d.y * sin(rot), -d.x * sin(rot) + d.y * cos(rot));
        return length(d / r) - 1.0;
    }

    fragment ColorDepth butterfly_fragment(SpriteOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float2 p = in.uv;                          // x 0..1 outward, y -1..1
        int style = int(in.a.z + 0.5);
        float hue = in.a.x, glow = in.a.w, opacity = in.b.x, seed = in.b.w;
        // wing shape: forewing + hindwing
        float fore = ellipse(p, float2(0.52, 0.36), float2(0.5, 0.36), 0.55);
        float hind = ellipse(p, float2(0.4, -0.38), float2(0.36, 0.34), -0.4);
        if (style == 5) { // origami: crisp triangles
            fore = max(max(-p.x, p.y - 0.95 + p.x * 0.3), -(p.y - 0.02 - p.x * 0.1)) ;
            fore = max(fore, p.x - 1.0);
            hind = max(max(-p.x, -(p.y + 0.75 - p.x * 0.2)), p.y + 0.02);
            hind = max(hind, p.x - 0.75);
        }
        float d = min(fore, hind);
        float body = length(float2(p.x / 0.05, p.y / 0.55)) - 1.0;
        float alpha = smoothstep(0.06, -0.02, d);
        float isBody = smoothstep(0.2, -0.2, body);
        alpha = max(alpha, isBody);
        if (alpha < 0.04) { discard_fragment(); }
        float edge = smoothstep(-0.28, -0.04, d);           // 1 near the outline
        float ang = atan2(p.y, p.x);
        float veins = smoothstep(0.92, 1.0, abs(sin(ang * 7.0 + p.x * 2.0)));
        float3 tint = hsv(hue, 0.65, 1.0);
        float3 col; float a = alpha; float emissive = 0.0;
        float t = u.a.z;
        if (style == 1) {        // Monarch
            float3 orange = mix(float3(1.0, 0.45, 0.05), tint, 0.25);
            col = mix(orange, float3(0.02), max(veins * 0.9, edge));
            float dots = step(0.82, hash21(floor(p * 14.0) + seed)) * edge;
            col = mix(col, float3(1.0), dots);
        } else if (style == 2) { // Glasswing
            col = mix(float3(0.9, 0.95, 1.0) * 0.6, float3(0.25, 0.12, 0.05), edge);
            a *= mix(0.22, 1.0, edge);
            emissive = 0.15 * (1.0 - edge);
        } else if (style == 3) { // Morpho Blue: thin-film iridescence
            float film = in.a.y * 0.6 + p.y * 0.35 + p.x * 0.2 + t * 0.05;
            float3 irid = 0.5 + 0.5 * cos(6.28318 * (film + float3(0.0, 0.33, 0.67)));
            float3 blue = float3(0.05, 0.35, 1.0);
            col = mix(blue, irid, u.look.x * 0.7) * (1.0 - edge * 0.85);
            emissive = 0.5 + 0.6 * u.look.x;
        } else if (style == 4) { // Moth
            col = mix(float3(0.62, 0.55, 0.45), float3(0.35, 0.28, 0.2), fbm(p * 9.0 + seed * 10.0)) * (1.0 - edge * 0.4);
            col = mix(col, tint * 0.6, 0.15);
        } else if (style == 5) { // Origami
            float facet = step(0.0, p.y - p.x * 0.4) * 0.25 + step(0.5, p.x) * 0.15;
            col = tint * (0.65 + facet) + 0.05;
        } else if (style == 6) { // Crystal
            col = mix(float3(0.85, 0.92, 1.0), tint, 0.25) * 0.55;
            float facets = abs(sin(p.x * 18.0 + p.y * 11.0)) * abs(sin(p.y * 16.0 - p.x * 7.0));
            emissive = 0.6 * smoothstep(0.85, 1.0, facets) + 0.8 * edge;
            a *= 0.75;
        } else if (style == 7) { // Neon
            col = float3(0.02);
            emissive = 2.5 * edge + 0.8 * veins;
            col += tint * emissive;
            emissive = 0.0;
        } else {                 // Petal
            col = mix(float3(1.0, 0.85, 0.9), tint, 0.4) * (0.75 + 0.35 * (1.0 - length(p - float2(0.3, 0.0))));
        }
        // shimmer: a light sweep across the wings as they beat
        float sweep = smoothstep(0.85, 1.0, sin(p.x * 4.0 + in.a.y * 6.28318 * 0.5 + seed * 6.0));
        col += float3(1.0) * sweep * u.look.y * 0.35 * (1.0 - edge);
        col += tint * emissive;
        col *= 1.0 + glow * 0.8;
        col = mix(col, float3(0.03, 0.02, 0.02), isBody);
        // farther butterflies sit in the haze
        col = mix(col, u.skyHorizon.rgb * 0.9, in.z * u.sun.w * 0.5);
        ColorDepth o;
        o.color = float4(col, a * opacity);
        o.depth = float4(in.z, 0, 0, 1);
        return o;
    }

    fragment ColorDepth bloom_fragment(SpriteOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float2 p = in.uv;
        float hue = in.a.x, open = in.a.y; int kind = int(in.a.z + 0.5);
        float r = length(p), ang = atan2(p.y, p.x) + in.a.w * 6.0;
        float n = kind == 2 ? 4.0 : kind == 3 ? 8.0 : kind == 4 ? 6.0 : 5.0;
        float petal;
        if (kind == 3) { petal = pow(abs(cos(ang * n * 0.5)), 0.45); }          // lotus: pointed
        else if (kind == 5) { petal = abs(cos(ang * n * 0.5)) * (1.0 - 0.25 * smoothstep(0.9, 1.0, abs(cos(ang * n * 0.5)))); } // cherry: notched
        else { petal = 0.55 + 0.45 * abs(cos(ang * n * 0.5)); }
        float radius = open * (kind == 1 ? 0.75 : 0.9) * petal;
        float shape = smoothstep(radius + 0.03, radius - 0.03, r);
        if (kind == 1) { shape = max(shape, smoothstep(open * 0.55 + 0.03, open * 0.55 - 0.03, r) * 1.0); } // rose: layered
        if (shape < 0.03) { discard_fragment(); }
        float3 petalCol = hsv(hue, kind == 5 ? 0.25 : 0.6, 1.0) * (0.55 + 0.45 * (r / max(radius, 0.01)));
        float centre = smoothstep(0.2 * open, 0.12 * open, r);
        float3 col = mix(petalCol, float3(1.0, 0.8, 0.25), centre);
        col *= mix(1.0, 0.35, u.skyTop.w);
        col += float3(1.0, 0.85, 0.6) * u.sun.z * 0.15 * (1.0 - u.skyTop.w);
        ColorDepth o;
        o.color = float4(col, shape * in.b.x);
        o.depth = float4(in.z, 0, 0, 1);
        return o;
    }

    // Soft additive dot for butterfly trails (sprite_vertex with side 0).
    fragment ColorDepth trail_fragment(SpriteOut in [[stage_in]]) {
        float f = exp(-dot(in.uv, in.uv) * 2.5);
        ColorDepth o;
        o.color = float4(hsv(in.a.x, 0.45, 1.0) * f * in.b.x, 1.0);
        o.depth = float4(1.0, 0, 0, 0);
        return o;
    }

    // ---------- pollen, petals, fireflies (stateless procedural particles) ----------
    struct ParticleOut { float4 pos [[position]]; float2 uv; float4 color; };
    vertex ParticleOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant SceneU& u [[buffer(0)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float i = float(iid);
        float t = u.a.z;
        float pollenN = u.counts.x, petalN = u.counts.y;
        float3 p; float size; float4 col;
        float breeze = u.air.x;
        if (i < pollenN) {
            float3 h = float3(hash11(i), hash11(i + 7.1), hash11(i + 13.3));
            p = float3(fract(h.x + t * (0.004 + 0.02 * breeze)), 0.12 + 0.85 * fract(h.y + 0.01 * sin(t * 0.3 + i)), h.z);
            size = 0.0025 * (1.2 - p.z);
            float tw = 0.5 + 0.5 * sin(t * (1.0 + h.z * 3.0) + i);
            col = float4(1.0, 0.9, 0.6, 1.0) * u.air.y * tw * (1.0 - u.skyTop.w * 0.7) * 1.6;
        } else if (i < pollenN + petalN) {
            float j = i - pollenN;
            float3 h = float3(hash11(j + 31.0), hash11(j + 41.0), hash11(j + 53.0));
            float fall = fract(h.y - t * (0.025 + 0.02 * h.z));
            p = float3(fract(h.x + t * (0.01 + 0.05 * breeze) + 0.03 * sin(t * 1.3 + j)), 0.1 + 0.9 * fall, h.z);
            size = 0.007 * (1.3 - p.z);
            col = float4(1.0, 0.75, 0.82, 1.0) * u.air.z * 0.9;
        } else {
            float j = i - pollenN - petalN;
            float3 h = float3(hash11(j + 71.0), hash11(j + 83.0), hash11(j + 97.0));
            p = float3(fract(h.x + 0.03 * sin(t * 0.4 + j)), 0.05 + 0.3 * h.y + 0.04 * sin(t * 0.7 + j * 2.0), h.z);
            size = 0.004 * (1.3 - p.z);
            float blink = smoothstep(0.6, 1.0, sin(t * (0.8 + h.z) + j * 3.0));
            col = float4(0.75, 1.0, 0.35, 1.0) * u.air.w * blink * 3.0;
        }
        float aspect = u.a.x / u.a.y;
        float2 clip = toClip(p, u);
        ParticleOut o;
        o.pos = float4(clip + float2(c[vid].x / aspect, c[vid].y) * size * 2.0, 0, 1);
        o.uv = c[vid];
        o.color = col;
        return o;
    }
    fragment ColorDepth particle_fragment(ParticleOut in [[stage_in]]) {
        float f = exp(-dot(in.uv, in.uv) * 3.0);
        ColorDepth o;
        o.color = float4(in.color.rgb * f, 1.0);
        o.depth = float4(1.0, 0, 0, 0);
        return o;
    }

    // ---------- keys ----------
    struct KeyInstance { float4 rect; float4 info; };   // rect x0,y0,x1,y1 clip; info isBlack, glow, pressed
    struct KeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex KeyOut keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant KeyInstance* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        KeyInstance k = keys[iid];
        KeyOut o; o.uv = c[vid]; o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1); o.info = k.info; return o;
    }
    fragment ColorDepth keys_fragment(KeyOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float isBlack = in.info.x, glow = in.info.y, pressed = in.info.z;
        int finish = int(u.keyGlow.w + 0.5);
        float2 uv = in.uv;
        float3 white = float3(0.95, 0.92, 0.86), black = float3(0.05, 0.045, 0.04);
        if (finish == 1) { white = float3(0.82, 0.8, 0.76); black = float3(0.12, 0.11, 0.1); }          // Satin
        else if (finish == 2) { white = float3(0.96, 0.89, 0.74); black = float3(0.1, 0.07, 0.05); }   // Ivory
        else if (finish == 3) { white = float3(0.75, 0.77, 0.8); black = float3(0.25, 0.26, 0.28); }   // Brushed metal
        else if (finish == 4) { white = float3(1.0, 0.82, 0.45); black = float3(0.35, 0.22, 0.06); }   // Gold
        else if (finish == 5) { white = float3(0.96, 0.95, 0.98); black = float3(0.2, 0.18, 0.24); }   // Pearl
        float3 col = isBlack > 0.5 ? black : white * mix(0.82, 1.0, uv.y);
        if (finish == 3) { col *= 0.92 + 0.08 * fract(sin(uv.y * 900.0) * 43758.5); }
        if (finish == 5) { col += (0.5 + 0.5 * cos(6.28318 * (uv.y * 0.6 + uv.x + float3(0.0, 0.33, 0.67)))) * 0.08; }
        if (finish == 0 || finish == 4) { col += float3(0.12) * smoothstep(0.85, 1.0, uv.y) * isBlack; }
        if (pressed > 0.5) col *= isBlack > 0.5 ? 1.3 : 0.9;
        float edge = 1.0 - smoothstep(0.0, 0.18, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
        col = mix(col, u.keyGlow.rgb, glow * 0.3);
        col += u.keyGlow.rgb * glow * edge * 1.6;
        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(0.0, 0, 0, 1);
        return o;
    }
    """
}
