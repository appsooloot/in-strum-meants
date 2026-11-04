/// Metal source for the Window Kit (spec §7): frosted glass with warm patches, condensation, stuck flakes, drips and
/// the room's reflection; the window frame (log wood or a painted sash); and the half-resolution blur that frosted
/// glass scatters on High and Ultra. Compiled at runtime.
/// Smooth-quality rules: no ray marching, at most 2 noise octaves here; squares are written out (no pow).
enum WindowKitShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ColorDepth { float4 color [[color(0)]]; float4 depth [[color(1)]]; };

    struct GlassU {
        float4 rect;        // NDC x0, y0, x1, y1 of the glass
        float4 a;           // frost level, condensation, time, blur on (0/1)
        float4 glint;       // inside light rgb, outside light amount
        float4 reflection;  // the room's glow rgb, strength
        float4 light;       // outside light rgb (the scene's average), field ready (0/1)
        float4 b;           // patch count, bar count, material (0 log wood, 1 painted sash), frame width (NDC x)
        float4 c;           // aspect (w/h), quality (0 Smooth), sparkle scale (gentle visuals halve glints), unused
        float4 bars[19];    // lo, hi (window coordinates), kind (0 vertical: x; 1 horizontal: y)
        float4 patches[48]; // x, y (window, y up), radius (of the width), warmth
    };

    constexpr sampler lin(filter::linear, mip_filter::linear, address::clamp_to_edge);

    float h21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    float vn2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(h21(i), h21(i + float2(1, 0)), u.x), mix(h21(i + float2(0, 1)), h21(i + float2(1, 1)), u.x), u.y);
    }

    constant float2 quadCorners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };

    // The pane around a window point (x0, y0, x1, y1), and whether the point is on a bar.
    float4 paneAt(float2 w, constant GlassU& u, thread bool& onBar) {
        float4 p = float4(0, 0, 1, 1);
        onBar = false;
        int n = int(u.b.y + 0.5);
        for (int i = 0; i < 19; i++) {
            if (i >= n) break;
            float4 bar = u.bars[i];
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

    // Until the frost field has grown: frost from the corners and edges inwards.
    float fallbackArrival(float2 w, float4 p, float2 cells) {
        float2 d0 = (w - p.xy) * cells, d1 = (p.zw - w) * cells;
        float edge = min(min(d0.x, d0.y), min(d1.x, d1.y));
        float halfSpan = 0.5 * min((p.z - p.x) * cells.x, (p.w - p.y) * cells.y);
        float corner = min(min(length(d0), length(float2(d1.x, d0.y))), min(length(float2(d0.x, d1.y)), length(d1)));
        float t = min(edge, corner * 0.7) / max(halfSpan, 1.0);
        return clamp(t * 1.05 + (vn2(w * cells / 9.0) - 0.5) * 0.08, 0.0, 1.0);
    }

    // ---------------------------------------------------------------- glass
    struct GlassOut { float4 pos [[position]]; float2 win; };

    vertex GlassOut glass_vertex(uint vid [[vertex_id]], constant GlassU& u [[buffer(0)]]) {
        float2 q = quadCorners[vid];
        GlassOut o;
        o.win = q;
        o.pos = float4(mix(u.rect.xy, u.rect.zw, q), 0, 1);
        return o;
    }

    fragment float4 glass_fragment(GlassOut in [[stage_in]], constant GlassU& u [[buffer(0)]],
                                   texture2d<float> field [[texture(0)]], texture2d<float> blur [[texture(1)]]) {
        float2 w = in.win;
        bool onBar;
        float4 pane = paneAt(w, u, onBar);
        if (onBar) return float4(0);
        float2 cells = float2(384.0, 216.0);          // the frost field's grid
        float2 cp = float2(w.x, 1.0 - w.y) * cells;   // cell space, rows down as the field is stored
        float3 inside = u.glint.rgb;
        float3 outside = u.light.rgb;
        float time = u.a.z;

        // Warm patches lower the frost level around them; as they cool, frost regrows in the field's own order.
        float clearing = 0.0;
        int np = int(u.b.x + 0.5);
        for (int i = 0; i < 48; i++) {
            if (i >= np) break;
            float4 p = u.patches[i];
            float2 d = (w - p.xy) * float2(1.0, cells.y / cells.x);
            float m = 1.0 - smoothstep(0.55, 1.0, length(d) / max(p.z, 1e-4));
            clearing = max(clearing, p.w * m);
        }
        float frostLevel = u.a.x * (1.0 - clearing);

        float arrival;
        float2 grad = float2(0, 1);
        float vein = 0.0;
        if (u.light.w > 0.5) {
            float2 fuv = float2(w.x, 1.0 - w.y), e = 1.0 / cells;
            arrival = field.sample(lin, fuv).r;
            float xp = field.sample(lin, fuv + float2(e.x, 0)).r, xm = field.sample(lin, fuv - float2(e.x, 0)).r;
            float yp = field.sample(lin, fuv + float2(0, e.y)).r, ym = field.sample(lin, fuv - float2(0, e.y)).r;
            grad = float2(xp - xm, yp - ym);
            // The needles arrived before the cells beside them: a one-cell high-pass finds them, so the frost keeps
            // its fern veins everywhere, not only at the front.
            vein = saturate((0.25 * (xp + xm + yp + ym) - arrival) * 40.0);
        } else {
            arrival = fallbackArrival(w, pane, cells);
        }

        // Fine crystal detail: streaks along the growth direction (2 octaves) feather the front.
        float gl = length(grad);
        float2 g = gl > 1e-6 ? grad / gl : float2(0, 1);
        float2 q = float2(dot(cp, g), dot(cp, float2(-g.y, g.x)));
        float streak = vn2(float2(q.x * 0.35, q.y * 2.2)) * 0.65 + vn2(float2(q.x * 0.8, q.y * 5.3) + 7.1) * 0.35;
        float edge = frostLevel - arrival + (streak - 0.5) * 0.035;
        float cover = smoothstep(-0.012, 0.02, edge) * smoothstep(0.0, 0.02, frostLevel);
        float age = smoothstep(0.0, 0.22, edge);

        // What the frost scatters: the blurred view itself (High/Ultra), or the scene's average light (Smooth).
        float3 scatter = outside;
        if (u.a.w > 0.5) {
            float2 suv = in.pos.xy / (2.0 * float2(blur.get_width(), blur.get_height()));
            scatter = min(blur.sample(lin, suv, level(2.5)).rgb, float3(6.0)) * 1.25 + outside * 0.12;
        }
        float3 albedo = float3(0.88, 0.93, 1.0);
        // Frost scatters far more light than clear glass lets through: it reads white over the view, lit by the room.
        // Firelight on frost reads warm white, not orange: the room light is half desaturated on the crystals.
        float3 roomOnFrost = mix(inside, float3(dot(inside, float3(0.2126, 0.7152, 0.0722))), 0.5) * 1.5;
        float3 col = albedo * (scatter * 1.3 + 0.02 + roomOnFrost * 0.45 * (0.6 + 0.4 * streak));
        // Faint ribs where the fronts paused, and brighter fern veins along the needles, on the older frost.
        float ribs = 0.5 + 0.5 * sin(arrival * 260.0 + streak * 3.0);
        col *= (0.9 + 0.12 * ribs * age) * (0.85 + 0.4 * vein);
        float alpha = cover * mix(0.42, 0.9, age) * mix(0.72 + 0.28 * streak, 1.0, vein);

        // Glints: hashed facets that twinkle with the light falling on them (warm room light, sun or moon outside).
        float2 gp = floor(in.pos.xy * 0.5);
        float hsh = h21(gp + 0.5);
        float tw = 0.5 + 0.5 * sin(time * (1.3 + 2.7 * h21(gp + 7.7)) + hsh * 40.0);
        tw *= tw; tw *= tw; tw *= tw;
        float sparkle = step(0.985, hsh) * tw * cover * age * u.c.z;
        float3 glints = (inside * 1.4 + outside * u.glint.w * 1.6) * sparkle * 1.8;

        // Condensation: a soft fog band along the bottom of the pane.
        float paneH = pane.w - pane.y;
        float band = u.a.y * 0.22 * paneH;
        float fogT = band > 1e-5 ? (w.y - pane.y) / band : 9.0;
        float fogN = vn2(float2(cp.x / 7.0, time * 0.05));
        float fog = u.a.y * (1.0 - smoothstep(0.35 + 0.3 * fogN, 1.0, fogT));
        float fogA = fog * 0.5;
        float3 fogCol = scatter * 0.95 + inside * 0.1 + 0.04;

        // The room's light, faintly reflected (only shows when outside is darker).
        float2 rc = w - float2(0.12, 0.08);
        float3 reflection = u.reflection.rgb * u.reflection.w * (0.35 + 0.65 * exp(-dot(rc, rc) * 3.0));

        float3 premul = col * alpha;
        premul = premul * (1.0 - fogA) + fogCol * fogA;
        float a = 1.0 - (1.0 - alpha) * (1.0 - fogA);
        return float4(premul + glints + reflection, a);
    }

    // ---------------------------------------------------------------- flakes and drips on the glass
    // instance: a = (x, y NDC, size NDC x, alpha); b = (rotation, kind 0 flake / 1 drip, trail NDC, light)
    struct GlassDrop { float4 a; float4 b; };
    struct DropOut { float4 pos [[position]]; float2 uv; float alpha; float kind; float rot; float trail; float light; };

    vertex DropOut glassdrop_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    constant GlassU& u [[buffer(0)]], constant GlassDrop* ds [[buffer(1)]]) {
        float2 q = quadCorners[vid] * 2.0 - 1.0;
        GlassDrop d = ds[iid];
        float2 size = float2(d.a.z, d.a.z * u.c.x);
        DropOut o;
        o.kind = d.b.y; o.rot = d.b.x; o.alpha = d.a.w; o.light = d.b.w;
        o.trail = d.b.z / max(size.y, 1e-5);
        float2 off;
        if (d.b.y < 0.5) {
            off = q * size;
            o.uv = q;
        } else {
            // A drip: the bead at the bottom, its trail above.
            float y = q.y < 0.0 ? -size.y : max(d.b.z, size.y);
            off = float2(q.x * size.x, y);
            o.uv = float2(q.x, y / size.y);
        }
        o.pos = float4(d.a.xy + off, 0, 1);
        return o;
    }

    fragment float4 glassdrop_fragment(DropOut in [[stage_in]]) {
        float2 p = in.uv;
        float a;
        float3 col;
        if (in.kind < 0.5) {
            // A stuck flake: six arms with little side twigs, melting from the tips.
            float r = length(p);
            float ang = atan2(p.y, p.x) + in.rot;
            float arm = abs(sin(3.0 * ang)) * r;
            float star = (1.0 - smoothstep(0.03, 0.1, arm)) * (1.0 - smoothstep(0.7, 1.0, r));
            float twigAng = abs(sin(3.0 * ang + 1.0472)) * r;
            float twig = (1.0 - smoothstep(0.02, 0.07, twigAng)) * smoothstep(0.35, 0.45, r) * (1.0 - smoothstep(0.55, 0.65, r));
            float core = 1.0 - smoothstep(0.08, 0.2, r);
            a = saturate(star + twig * 0.8 + core) * in.alpha;
            col = float3(0.94, 0.97, 1.0) * in.light;
        } else {
            // A drip: a lens-like bead with a bright rim and highlight, and a thin wet trail fading upwards.
            float r = length(p);
            float bead = 1.0 - smoothstep(0.8, 1.0, r);
            float rim = smoothstep(0.5, 0.9, r) * bead;
            float2 hp = p - float2(-0.3, 0.35);
            float hi = exp(-dot(hp, hp) * 18.0);
            float trail = p.y > 0.0 ? (1.0 - smoothstep(0.15, 0.4, abs(p.x))) * (1.0 - smoothstep(0.0, max(in.trail, 0.01), p.y)) * 0.35 : 0.0;
            a = saturate(bead * 0.25 + rim * 0.5 + hi + trail) * in.alpha;
            col = float3(0.82, 0.88, 0.96) * in.light + hi * 0.6;
        }
        return float4(col * a, a);
    }

    // ---------------------------------------------------------------- frame
    struct FrameOut { float4 pos [[position]]; float2 ndc; };

    vertex FrameOut frame_vertex(uint vid [[vertex_id]], constant GlassU& u [[buffer(0)]]) {
        float fw = u.b.w, fh = u.b.w * u.c.x;
        float4 r = u.rect + float4(-fw, -fh, fw, fh);
        float2 p = mix(r.xy, r.zw, quadCorners[vid]);
        FrameOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    fragment ColorDepth frame_fragment(FrameOut in [[stage_in]], constant GlassU& u [[buffer(0)]]) {
        float2 p = in.ndc;
        float4 r = u.rect;
        float fw = u.b.w, fh = u.b.w * u.c.x;
        float2 w = (p - r.xy) / max(r.zw - r.xy, float2(1e-5));
        // Which member: `across` runs −1…1 over its width, `along` along its length (in frame widths).
        float across = 2.0, along = 0.0;
        bool vertical = true;
        if (p.x < r.x) { across = (p.x - (r.x - 0.5 * fw)) / (0.5 * fw); along = p.y / fw; }
        else if (p.x > r.z) { across = (p.x - (r.z + 0.5 * fw)) / (0.5 * fw); along = p.y / fw; }
        else if (p.y < r.y) { across = (p.y - (r.y - 0.5 * fh)) / (0.5 * fh); along = p.x / fw; vertical = false; }
        else if (p.y > r.w) { across = (p.y - (r.w + 0.5 * fh)) / (0.5 * fh); along = p.x / fw; vertical = false; }
        else {
            int n = int(u.b.y + 0.5);
            for (int i = 0; i < 19; i++) {
                if (i >= n) break;
                float4 bar = u.bars[i];
                float v = bar.z < 0.5 ? w.x : w.y;
                if (v < bar.x || v > bar.y) continue;
                float a2 = (v - 0.5 * (bar.x + bar.y)) / max(0.5 * (bar.y - bar.x), 1e-5);
                // Vertical bars run through; horizontal bars sit between them.
                if (bar.z < 0.5) { across = a2; along = p.y / fw; vertical = true; break; }
                if (abs(across) > 1.0) { across = a2; along = p.x / fw; vertical = false; }
            }
            if (abs(across) > 1.0) discard_fragment();
        }
        across = clamp(across, -1.0, 1.0);
        float3 inside = u.glint.rgb;
        // The room's light comes from low and to the left (the fire), or evenly (morning light).
        float2 sp = saturate((p + 1.0) * 0.5);
        float roomFall = 1.15 - 0.55 * sp.x - 0.35 * sp.y;
        float3 col;
        if (u.b.z < 0.5) {
            // Log wood: a rounded log with grain along it and dark chinking where logs meet.
            float nz = sqrt(saturate(1.0 - across * across));
            float3 n = vertical ? float3(across, 0, nz) : float3(0, across, nz);
            float diff = saturate(dot(n, normalize(float3(-0.55, -0.45, 0.7))));
            float grain = vn2(float2(along * 2.2, across * 9.0)) * 0.6 + vn2(float2(along * 6.0, across * 23.0) + 3.1) * 0.4;
            float rings = 0.5 + 0.5 * sin(across * 7.0 + grain * 5.0);
            float3 albedo = mix(float3(0.2, 0.13, 0.08), float3(0.34, 0.23, 0.15), grain * 0.7 + rings * 0.3);
            float chink = 1.0 - smoothstep(0.82, 0.98, abs(across));
            col = albedo * (inside * (0.25 + 0.95 * diff * roomFall) + u.light.rgb * (0.12 + 0.3 * nz)) * mix(0.35, 1.0, chink);
        } else {
            // A painted sash: a flat face, chamfered inner edges catching or missing the light, brushed paint.
            float3 albedo = float3(0.88, 0.86, 0.81);
            float bevel = smoothstep(0.62, 0.95, abs(across));
            float facing = vertical ? -sign(across) : sign(across);
            float shade = 1.0 + bevel * 0.22 * facing;
            float brush = vn2(float2(along * 14.0, across * 3.0)) * 0.05;
            col = albedo * (inside * (0.55 + 0.45 * roomFall) * shade + u.light.rgb * 0.15) * (0.97 + brush);
            col *= mix(1.0, 0.6, smoothstep(0.95, 1.0, abs(across)));
        }
        ColorDepth o;
        o.color = float4(col, 1);
        o.depth = float4(0.02, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- blur (High/Ultra)
    struct FSOut { float4 pos [[position]]; float2 uv; };

    vertex FSOut glass_fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        FSOut o;
        o.pos = float4(p * 2.0 - 1.0, 0, 1);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 blur_down_fragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float3 c = src.sample(lin, in.uv + t * float2(-0.5, -0.5)).rgb + src.sample(lin, in.uv + t * float2(0.5, -0.5)).rgb
                 + src.sample(lin, in.uv + t * float2(-0.5, 0.5)).rgb + src.sample(lin, in.uv + t * float2(0.5, 0.5)).rgb;
        return float4(min(c * 0.25, float3(8.0)), 1);
    }

    // ---------------------------------------------------------------- the round porthole (spec §7.4)
    // Round glass is one pane inscribed in `rect` (a circle when the rect is square on screen), in a brass ring. It
    // draws no frost. Its glass is opaque when it has the view behind it (copied by makeView, sampled through the
    // thick acrylic's barrel warp), and only its fog and reflection otherwise.
    struct PortU {
        float4 view;    // the copied view's origin in target pixels (x, y) and its size (w, h)
        float4 centre;  // the glass's centre in target pixels (x, y), the barrel warp at the rim, view bound (0/1)
        float4 a;       // cold outside 0…1, bolt count, the first bolt's angle (radians), the bolts' circle (of the ring)
        float4 b;       // bolt head radius (of the ring's width), the gasket's width (of the ring's), unused, unused
    };

    constexpr sampler portLin(filter::linear, address::clamp_to_edge);

    /// The view through the acrylic at a pixel, warped `k` times as far out from the glass's centre.
    float3 portView(float2 pos, float k, constant PortU& pu, texture2d<float> view) {
        float2 px = pu.centre.xy + (pos - pu.centre.xy) * k - pu.view.xy;
        float2 uv = clamp(px, float2(0.5), max(pu.view.zw - 0.5, float2(0.5))) / float2(view.get_width(), view.get_height());
        return min(view.sample(portLin, uv, level(0.0)).rgb, float3(64.0));   // one level: no derivatives needed
    }

    fragment float4 port_glass_fragment(GlassOut in [[stage_in]], constant GlassU& u [[buffer(0)]],
                                        constant PortU& pu [[buffer(1)]], texture2d<float> view [[texture(0)]]) {
        float2 w = in.win;
        float2 c = w - 0.5;
        float rr = 2.0 * length(c);                       // 0 at the centre … 1 at the rim
        if (rr > 1.0) return float4(0);                   // outside the circle: the view is left as it was
        float time = u.a.z;
        float cond = u.a.y, cold = saturate(pu.a.x);
        float3 inside = u.glint.rgb, outside = u.light.rgb;
        bool bound = pu.centre.w > 0.5;

        // The view through thick acrylic: sampled farther out toward the rim (4% there), with a faint colour fringe
        // on High and Ultra, a green-blue cast thickening to the rim and the deep ring's shadow just inside it.
        float3 col = outside;
        if (bound) {
            float k = 1.0 + pu.centre.z * rr * rr;
            col = portView(in.pos.xy, k, pu, view);
            if (u.c.y > 0.5) {
                float spread = 0.004 * rr * rr;
                col.r = portView(in.pos.xy, k + spread, pu, view).r;
                col.b = portView(in.pos.xy, k - spread, pu, view).b;
            }
            col *= mix(float3(1.0), float3(0.9, 0.97, 0.95), rr * rr) * (1.0 - 0.45 * smoothstep(0.9, 1.0, rr));
        }

        // Condensation: warm damp air on glass the sea chills fogs it from the rim in, wider and denser the colder
        // the sea (deeper), gathering lowest; mottled (2 octaves) and beaded with droplets catching the cabin light.
        float2 dir = rr > 1e-5 ? c / (0.5 * rr) : float2(0.0, 1.0);
        float band = cond * (0.1 + 0.16 * cold) * (1.0 + 0.7 * saturate(-dir.y));
        float mottle = 0.65 * vn2(w * 7.0 + float2(0.0, time * 0.01)) + 0.35 * vn2(w * 23.0 + 3.7);
        float fogT = band > 1e-5 ? (1.0 - rr) / band : 9.0;
        float fog = cond * (1.0 - smoothstep(0.25 + 0.45 * mottle, 1.0, fogT)) * (0.75 + 0.25 * cold);
        float bead = step(0.93, h21(floor(in.pos.xy * 0.5) + 0.5)) * fog;
        float fogA = fog * 0.62;
        float3 fogCol = col * 0.55 + inside * 0.22 + 0.02 + inside * bead * 0.2;

        // The cabin, faintly mirrored in the acrylic: its lamp a soft glow high on the left.
        float2 rc = w - float2(0.28, 0.74);
        float3 refl = u.reflection.rgb * u.reflection.w * (0.25 + 0.75 * exp(-dot(rc, rc) * 9.0));
        if (bound) return float4(mix(col, fogCol, fogA) + refl, 1.0);
        return float4(fogCol * fogA + refl, fogA);
    }

    // The brass ring: a rubber gasket against the glass, an inner bevel down to it, a flat flange with hex bolts,
    // a rounded outer edge; polished brass brushed in circles, lit warm by the cabin and catching the sea's light on
    // the bevel. Drawn over `rect` ± the frame's width, discarding off the ring.
    fragment ColorDepth port_frame_fragment(FrameOut in [[stage_in]], constant GlassU& u [[buffer(0)]],
                                            constant PortU& pu [[buffer(1)]]) {
        float aspect = u.c.x;
        float2 centre = 0.5 * (u.rect.xy + u.rect.zw);
        float R = 0.5 * (u.rect.w - u.rect.y);          // the glass's radius (NDC-y units, round on screen)
        float W = max(u.b.w * aspect, 1e-5);             // the ring's width
        float2 q = (in.ndc - centre) * float2(aspect, 1.0);
        float r = length(q);
        if (r < R || r > R + W) discard_fragment();
        float s = (r - R) / W;                           // 0 at the glass … 1 at the ring's outside
        float2 radial = q / max(r, 1e-6);
        float ang = atan2(q.y, q.x);
        float gasket = pu.b.y;

        // The cross-section's tilt along the radius (+ facing out): the bevel leans toward the glass, the flange is
        // flat with a slight crown, the outer edge rolls away.
        float tilt = -0.62 * smoothstep(gasket, gasket + 0.03, s) * (1.0 - smoothstep(gasket + 0.17, gasket + 0.22, s))
                   + 0.12 * (s - 0.55) + 0.85 * smoothstep(0.84, 1.0, s);
        tilt = clamp(tilt, -0.9, 0.9);
        float3 nrm = normalize(float3(radial * tilt, 1.0));
        float occl = 1.0 - 0.5 * smoothstep(0.93, 1.0, s);
        float3 albedo = float3(0.8, 0.58, 0.26);
        bool rubber = s < gasket;

        // The bolts: hex heads on round washers at even angles round the flange, each in a dark ring of shadow.
        float stepA = 6.2831853 / max(pu.a.y, 1.0);
        float k = floor((ang - pu.a.z) / stepA + 0.5);
        float ba = pu.a.z + k * stepA;
        float2 bdir = float2(cos(ba), sin(ba));
        float2 v = q - bdir * (R + pu.a.w * W);
        float rb = pu.b.x * W;
        float2 lv = abs(float2(dot(v, bdir), dot(v, float2(-bdir.y, bdir.x))));
        float hex = max(lv.x * 0.8660254 + lv.y * 0.5, lv.y) / max(rb, 1e-6);
        float rv = length(v) / max(rb, 1e-6);
        if (!rubber) {
            if (hex < 1.0) {
                // A chamfered head: flat on top, its edges leaning out from the bolt's centre.
                float lean = 0.75 * smoothstep(0.6, 0.98, hex);
                nrm = normalize(float3(v / max(length(v), 1e-6) * lean, 1.0));
                albedo = float3(0.72, 0.52, 0.24);
                occl = 1.0;
            } else if (rv < 1.3) {
                nrm = float3(0.0, 0.0, 1.0);             // the washer
                albedo = float3(0.66, 0.5, 0.28);
            } else {
                occl *= mix(0.45, 1.0, smoothstep(1.3, 1.75, rv));
            }
        }

        // Brushed in circles (2 octaves, periodic round the ring), tarnished a little in patches.
        float2 around = float2(cos(ang), sin(ang));
        float grain = 0.6 * vn2(float2(s * 38.0, 0.0) + around * 2.5) + 0.4 * vn2(float2(s * 97.0, 5.1) + around * 6.0);
        float tarnish = 0.6 * vn2(q * 9.0) + 0.4 * vn2(q * 23.0 + 4.0);
        albedo *= 0.82 + 0.25 * tarnish;

        float3 Lc = normalize(float3(-0.45, 0.6, 0.66));    // the cabin's lamp: up and to the left, in front
        float3 H = normalize(Lc + float3(0.0, 0.0, 1.0));
        float diff = saturate(dot(nrm, Lc));
        float sh = saturate(dot(nrm, H));
        float s2 = sh * sh, s4 = s2 * s2, s8 = s4 * s4, s16 = s8 * s8, s32 = s16 * s16, s64 = s32 * s32;
        float3 cabin = u.glint.rgb, sea = u.light.rgb;
        float3 col;
        if (rubber) {
            // The gasket: black rubber, a soft bead with a dull sheen.
            float bead = sin(3.14159265 * saturate(s / max(gasket, 1e-4)));
            col = float3(0.03, 0.028, 0.026) * (0.4 + 0.6 * bead) * (0.4 + cabin) + cabin * (s16 * 0.06 * bead);
        } else {
            // Polished metal mirrors the room: the reflected ray looks up to the lit ceiling or down to the dim floor,
            // so the ring's rolls and bevels read as curves; the lamp's highlight runs along them, brushed in circles.
            float3 rv3 = float3(2.0 * nrm.z * nrm.xy, 2.0 * nrm.z * nrm.z - 1.0);
            float room = 0.2 + 0.8 * smoothstep(-0.55, 0.75, rv3.y);
            float spec = s64 * (1.4 + 1.2 * grain) + s8 * 0.25;
            float bevel = saturate(-tilt);
            col = albedo * cabin * (0.06 + 0.3 * diff + 0.55 * room + spec) + albedo * sea * (0.5 * bevel + 0.05) + albedo * 0.01;
            col *= occl;
        }
        ColorDepth o;
        o.color = float4(col, 1);
        o.depth = float4(0.02, 0, 0, 1);
        return o;
    }
    """
}
