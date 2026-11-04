/// Metal source for Zen Rock Garden: from the veranda of a temple hall, the raked white gravel of Rake Lines' height
/// field (a texture), lit by the sun or the moon with the ridges' own short shadows; five stones on moss islands (each
/// an ellipsoid sunk into its moss with a facet cut from it, met in closed form) throwing soft shadows; the granite kerb,
/// the moss banks and the drip line's pebbles; a low earthen wall with a tiled cap, the temple grounds' trees and a tall
/// cedar beyond it; a maple on the left bank in the season's colour; a bamboo water-knocker by its stone basin; and
/// keys of pale cypress along the veranda's edge. Built on SkyShaders.common (the sky shows where the garden discards).
/// Smooth rules: no ray marching (the gravel's shadows are two or three taps toward the light, the stones closed-form),
/// ≤ 3 noise octaves (2 on Smooth), the field read without a sampler (nine texels, four per shadow tap); everything that
/// moves is timed by the frame's wrapped clock. No pow(): powers are written out.
enum ZenRockGardenShaders {
    static let source = SkyShaders.common + """
    struct GardenU {
        float4 a;          // keys top (NDC y), aspect, eye height (m), night 0…1
        float4 b;          // day 0…1, relief (m per field unit, by Rake depth), moss reach (cells), wetness 0…1
        float4 c;          // snow cover 0…1, haze 0…1, wind 0…1, noise octaves (2 on Smooth)
        float4 bed;        // cell (m), the bed's near edge (m ahead), the wall's face (m ahead), kerb width (m)
        float4 wall;       // earthen wall height (m), tiled cap height (m), ridge shadow taps, quality (0 Smooth)
        float4 key;        // the light that throws shadows (sun or moon) in the garden's frame, how strongly it does
        float4 keyColor;   // its light (rgb, strength included), 1 when it is the sun
        float4 fill;       // the other light's direction, unused
        float4 fillColor;  // its light (rgb), unused
        float4 ambient;    // the sky's light (rgb), cloud cover
        float4 maple;      // leaf colour (linear rgb), canopy 0 bare … 1 full
        float4 mapleAt;    // trunk x (m), its plane (m ahead), sway (m), unused
        float4 knocker;    // tube angle (rad, + mouth up), fill 0…1, pour 0…1, clack 0…1
        float4 knockerAt;  // pivot x (m), its plane (m ahead), unused, unused
        float4 cedarAt;    // x (m), plane (m ahead), tip height (m), sway (m)
        float4 wave;       // a chord's fronts: left, right (bed x 0…1), width (bed units), brightness (limited)
        float4 waveColor;  // rgb (warm gold for major … cool silver for minor), unused
        float4 view;       // the view's level forward (east, north), time (s, wrapped), sparkle scale
        float4 counts;     // held rakes, the islands' blend (cells), unused, unused
        float4 stones[5];      // centre x, y (cells), footprint radius (cells), height (m)
        float4 stoneFrame[20]; // per stone: (long axis, semi-axis m), (short axis, …), (up axis, …), (centre, unused)
        float4 stoneCut[10];   // its two facets: outward normal (garden frame), offset (m: dot(n, p) ≤ offset is stone)
        float4 rakes[12];      // a held note's rake: x, y (cells), its ring's radius (cells), strength
    };
    struct GardenOut { float4 pos [[position]]; float2 ndc; };

    // The garden's frame: x to the right, y ahead from the eye, z up from the gravel (metres). Field cell (cx, cy) lies at
    // x = (cx − 128) × cell, y = near + (144 − cy) × cell.
    constant float3 kGravel = float3(0.68, 0.665, 0.62);
    constant float3 kSnow = float3(0.93, 0.95, 0.98);
    constant float3 kMoss = float3(0.05, 0.11, 0.034);
    constant float3 kBamboo = float3(0.27, 0.31, 0.12);
    constant float3 kRakeLight = float3(1.0, 0.93, 0.8);
    // The maple's tiers: centre (x from its trunk, z) and radii (m).
    constant float4 kMapleTiers[4] = {
        float4(1.15, 1.58, 1.55, 0.44), float4(1.95, 2.14, 1.45, 0.48), float4(0.75, 2.66, 1.3, 0.48), float4(1.3, 3.14, 0.95, 0.4)
    };

    vertex GardenOut garden_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        GardenOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    /// Distance from p to segment ab, and how far along it (0…1) the nearest point lies.
    float2 zgSeg(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
        return float2(length(pa - ba * h), h);
    }

    /// The rake field's own smooth minimum (RakeLines.smoothMin), so the moss islands are the field's.
    float zgSmoothMin(float a, float b, float k) {
        float h = max(k - abs(a - b), 0.0) / k;
        return min(a, b) - h * h * k * 0.25;
    }

    /// A point of the garden (x, y in metres) as a field cell (x 0…256 across, y 0 at the wall … 144 at the kerb).
    float2 zgCell(float2 q, constant GardenU& g) {
        return float2(128.0 + q.x / g.bed.x, 144.0 - (q.y - g.bed.y) / g.bed.x);
    }

    /// Haze over the garden: the horizon's colour gathering with distance (m), thicker in mist.
    float3 zgHaze(float3 col, float t, constant SkyU& u, constant GardenU& g) {
        float k = 1.0 - exp(-t * (0.0006 + 0.03 * g.c.y * g.c.y * g.c.y));
        return mix(col, u.horizon.rgb * (1.02 + 0.1 * g.a.w), saturate(k));
    }

    /// The key light (shadowed by `shade`, as strongly as the key throws shadows) and the fill on a surface facing n.
    float3 zgDirect(float3 n, float shade, constant GardenU& g) {
        float k = max(dot(n, g.key.xyz), 0.0) * mix(1.0, shade, g.key.w);
        return g.keyColor.rgb * k + g.fillColor.rgb * max(dot(n, g.fill.xyz), 0.0);
    }

    /// x^32 by squaring, for sheens.
    float zgSheen(float x) {
        float s = saturate(x);
        s *= s; s *= s; s *= s; s *= s; s *= s;
        return s;
    }

    // ---------------------------------------------------------------- the rake field
    /// One texel of the field (clamped to it): r32Float, read without a sampler (no float filtering needed).
    float zgTexel(texture2d<float, access::read> field, int x, int y) {
        return field.read(uint2(uint(clamp(x, 0, 255)), uint(clamp(y, 0, 143)))).r;
    }

    /// The relief at p (cells) by a quadratic B-spline over the 3 × 3 texels round it: its height and slope (per cell),
    /// smooth across texels so the light on the ridges has no seams.
    float3 zgRelief(texture2d<float, access::read> field, float2 p) {
        float2 q = p - 0.5;
        float2 cc = floor(q + 0.5);
        float2 t = q - cc;
        float2 lo = 0.5 - t, hi = 0.5 + t;
        float2 w0 = 0.5 * lo * lo, w1 = 0.75 - t * t, w2 = 0.5 * hi * hi;
        float2 d0 = -lo, d1 = -2.0 * t, d2 = hi;
        int x = int(cc.x), y = int(cc.y);
        float h = 0.0, hx = 0.0, hy = 0.0;
        for (int j = 0; j < 3; j++) {
            float wy = j == 0 ? w0.y : (j == 1 ? w1.y : w2.y);
            float dy = j == 0 ? d0.y : (j == 1 ? d1.y : d2.y);
            for (int i = 0; i < 3; i++) {
                float wx = i == 0 ? w0.x : (i == 1 ? w1.x : w2.x);
                float dx = i == 0 ? d0.x : (i == 1 ? d1.x : d2.x);
                float v = zgTexel(field, x + i - 1, y + j - 1);
                h += wx * wy * v;
                hx += dx * wy * v;
                hy += wx * dy * v;
            }
        }
        return float3(h, hx, hy);
    }

    /// The relief at p (cells), bilinear (the shadow taps).
    float zgReliefAt(texture2d<float, access::read> field, float2 p) {
        float2 q = p - 0.5;
        float2 i0 = floor(q), f = q - i0;
        int x = int(i0.x), y = int(i0.y);
        float a = zgTexel(field, x, y), b = zgTexel(field, x + 1, y);
        float c = zgTexel(field, x, y + 1), d = zgTexel(field, x + 1, y + 1);
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    /// The ridges' own shadows at p (cells), the snow lying at `level` in the grooves: a few taps toward the key light
    /// (1 lit … 0 in the shadow of the ridge before it).
    float zgRidgeShadow(texture2d<float, access::read> field, float2 p, float level, constant GardenU& g) {
        float3 L = g.key.xyz;
        float plan = length(L.xy);
        if (L.z <= 0.0 || plan < 1e-3) return 1.0;
        float2 dir = float2(L.x, -L.y) / plan;          // in cells: x right, y toward the veranda
        float rise = L.z / plan * g.bed.x;               // metres the light climbs over a cell
        float relief = g.b.y, soft = 0.25 * relief + 1e-4;
        float h0 = max(zgReliefAt(field, p), level);
        int taps = int(g.wall.z + 0.5);
        float occl = 0.0;
        for (int k = 1; k <= 3; k++) {
            if (k > taps) break;
            float dist = 1.15 * float(k);
            float h = max(zgReliefAt(field, p + dir * dist), level);
            occl = max(occl, (relief * (h - h0) - rise * dist) / soft);
        }
        return 1.0 - smoothstep(0.0, 1.0, occl);
    }

    /// How far (cells) p lies outside the nearest moss island (each island's stones blended into one outline, as the rake
    /// field's own: 0 and 1 the left pair, 2 the tall stone, 3 and 4 the right pair), and outside the nearest stone.
    float zgIsland(float2 p, constant GardenU& g, thread float& stone) {
        float k = g.counts.y;
        float d0 = length(p - g.stones[0].xy) - g.stones[0].z, d1 = length(p - g.stones[1].xy) - g.stones[1].z;
        float d2 = length(p - g.stones[2].xy) - g.stones[2].z;
        float d3 = length(p - g.stones[3].xy) - g.stones[3].z, d4 = length(p - g.stones[4].xy) - g.stones[4].z;
        stone = min(min(min(d0, d1), min(d3, d4)), d2);
        return min(min(zgSmoothMin(d0, d1, k), d2), zgSmoothMin(d3, d4, k));
    }

    // ---------------------------------------------------------------- the stones
    /// Stone i along the ray o + t·d (garden frame, d unit; `px` the pixel's angle): an ellipsoid sunk into its moss with
    /// two facets cut from it. Returns its cover of the pixel (soft over a pixel at its outline, 0 clear of it) and writes
    /// where the ray meets it, the normal there and how far inside its outline the ray passes (m).
    float zgStone(int i, float3 o, float3 d, float px, constant GardenU& g, thread float& tHit, thread float3& nrm,
                  thread float& inside) {
        float4 f1 = g.stoneFrame[4 * i], f2 = g.stoneFrame[4 * i + 1], f3 = g.stoneFrame[4 * i + 2];
        float3 ax = float3(f1.w, f2.w, f3.w);
        float3 oc = o - g.stoneFrame[4 * i + 3].xyz;
        float3 ol = float3(dot(oc, f1.xyz), dot(oc, f2.xyz), dot(oc, f3.xyz)) / ax;
        float3 dl = float3(dot(d, f1.xyz), dot(d, f2.xyz), dot(d, f3.xyz)) / ax;
        float A = dot(dl, dl), B = dot(ol, dl), C = dot(ol, ol) - 1.0;
        float tc = -B / A;
        if (tc <= 0.0) return 0.0;
        float3 qc = ol + dl * tc;
        float r = length(qc);
        float edge = (1.0 - r) * r / max(length(qc / ax), 1e-5);   // metres inside the outline (< 0 outside)
        float pix = tc * px;
        if (edge < -pix) return 0.0;
        float disc = B * B - A * C;
        float t0 = tc, t1 = tc;
        float3 q = qc / max(r, 1e-4);                              // a ray only grazing it: the outline's nearest point
        if (disc > 0.0) {
            float sq = sqrt(disc);
            t0 = (-B - sq) / A;
            t1 = (-B + sq) / A;
            q = ol + dl * t0;
        }
        float3 n = normalize((q.x / ax.x) * f1.xyz + (q.y / ax.y) * f2.xyz + (q.z / ax.z) * f3.xyz);
        for (int k = 0; k < 2; k++) {
            float4 cut = g.stoneCut[2 * i + k];
            float pn = dot(cut.xyz, o) - cut.w, pd = dot(cut.xyz, d);
            if (disc > 0.0) {
                if (abs(pd) > 1e-6) {
                    float tp = -pn / pd;
                    if (pd < 0.0) {
                        if (tp > t0) { t0 = tp; n = cut.xyz; }
                    } else {
                        t1 = min(t1, tp);
                    }
                } else if (pn > 0.0) {
                    return 0.0;
                }
            } else if (pn + pd * tc > 0.0) {
                return 0.0;                                        // the grazing point was cut away
            }
        }
        if (disc > 0.0 && (t0 >= t1 || t1 <= 0.0)) return 0.0;
        tHit = max(t0, 1e-3);
        nrm = n;
        inside = edge;
        return saturate(edge / pix + 0.5);
    }

    /// How much of the key light reaches p past the stones (1 lit … 0 in a stone's shadow, its edge softening away from
    /// the stone). `skip` leaves one stone out (its own terminator shades it).
    float zgStoneShadow(float3 p, int skip, constant GardenU& g) {
        float3 L = g.key.xyz;
        if (L.z <= 0.0) return 1.0;
        float lit = 1.0;
        for (int i = 0; i < 5; i++) {
            if (i == skip) continue;
            float4 f1 = g.stoneFrame[4 * i], f2 = g.stoneFrame[4 * i + 1], f3 = g.stoneFrame[4 * i + 2];
            float3 ax = float3(f1.w, f2.w, f3.w);
            float3 oc = p - g.stoneFrame[4 * i + 3].xyz;
            float3 ol = float3(dot(oc, f1.xyz), dot(oc, f2.xyz), dot(oc, f3.xyz)) / ax;
            float3 dl = float3(dot(L, f1.xyz), dot(L, f2.xyz), dot(L, f3.xyz)) / ax;
            float tc = -dot(ol, dl) / dot(dl, dl);
            if (tc <= 0.0) continue;
            float r = length(ol + dl * tc);
            float soft = 0.03 + 0.005 * tc / max(min(ax.x, ax.y), 0.05);   // the sun's half-degree, widening away
            lit *= smoothstep(1.0 - soft, 1.0 + soft, r);
        }
        return lit;
    }

    /// The wall's shadow on a point of the garden (1 lit … 0) when the light comes over its cap from beyond.
    float zgWallShadow(float3 p, constant GardenU& g) {
        float3 L = g.key.xyz;
        if (L.y <= 1e-4 || L.z <= 0.0) return 1.0;
        float top = g.wall.x + g.wall.y;
        float t = (g.bed.z - p.y) / L.y;
        if (t <= 0.0) return 1.0;
        float soft = 0.01 + 0.012 * t;
        return smoothstep(top - soft, top + soft, p.z + t * L.z);
    }

    /// A stone's face: weathered granite, grey with ochre and pale lichen, darker and glossy when wet, capped with snow,
    /// frosted on its windward side in rime; lit by the key light (the other stones' shadows on it), the sky, and the
    /// white gravel's light bounced up under it.
    float3 zgStoneColor(int i, float3 P, float3 n, float3 d, float t, float inside, constant SkyU& u, constant GardenU& g) {
        int oct = int(g.c.w + 0.5);
        float3 lp = (P - g.stoneFrame[4 * i + 3].xyz) * 7.0 + float3(float(i) * 17.3, 3.1, 0.0);
        float n1 = fbm3(lp, oct);
        float n2 = vnoise3(lp * 5.3 + 5.0);
        float grit = vnoise3(lp * 3.2 + 11.0);
        float3 bump = float3(vnoise3(lp * 2.0 + 1.0), vnoise3(lp * 2.0 + 9.0), vnoise3(lp * 2.0 + 17.0)) - 0.5;
        float3 nb = normalize(n + 0.35 * (bump - n * dot(bump, n)));
        float tone = hash13(float3(float(i), 2.0, 5.0));
        float3 rock = mix(float3(0.24, 0.225, 0.2), float3(0.33, 0.29, 0.23), tone) * (0.7 + 0.5 * n1) * (0.88 + 0.24 * grit);
        rock = mix(rock, float3(0.44, 0.45, 0.4), 0.3 * smoothstep(0.68, 0.84, n2) * smoothstep(0.35, 0.6, n1));   // lichen
        rock *= 0.62 + 0.38 * smoothstep(0.0, 0.12, P.z);                                  // its foot in the moss's shade
        float wet = g.b.w, rime = saturate(u.still.y);
        rock *= 1.0 - 0.45 * wet;
        rock = mix(rock, kSnow, g.c.x * smoothstep(0.5, 0.7, n.z + 0.1 * (grit - 0.5)));   // on slopes under about 60°
        rock = mix(rock, rimeColor(u) * 0.8, 0.3 * rime * saturate(0.2 - 1.5 * nb.x));    // the windward face frosted
        float shade = zgStoneShadow(P, i, g);
        float3 sky = g.ambient.rgb * (0.55 + 0.45 * nb.z);
        float3 ground = mix(kGravel * (1.0 - 0.42 * wet), kSnow, g.c.x);   // the gravel (or the snow on it) lights it from below
        float3 bounce = (g.ambient.rgb + g.keyColor.rgb * (0.8 * max(g.key.z, 0.0))) * ground * (0.32 * (1.0 - 0.6 * nb.z));
        float3 col = rock * (sky + zgDirect(nb, shade, g) + bounce);
        if (wet > 0.01) {
            col += g.keyColor.rgb * (wet * 0.5 * zgSheen(dot(reflect(d, nb), g.key.xyz)) * shade);
            col += u.horizon.rgb * (wet * 0.05);
        }
        float tv = t * u.up.w;
        float fringe = rimeEdge(u, inside / tv, float2(n.x, n.z), float2(P.x, P.z) / tv);
        return mix(col, rimeColor(u), fringe);
    }

    // ---------------------------------------------------------------- the gravel, moss, kerbs, banks and drip line
    /// The raked gravel (and the moss islands on it) at P, met along d at distance t: the rake field's relief lit by the
    /// key light with the ridges' own short shadows, the stones' and the wall's shadows, the sky's light (less in the
    /// grooves), snow filling the grooves, rain darkening it and dulling its lines, and the chord wave's and the held
    /// rakes' light. Grooves finer than about two pixels calm to their mean, across and along the view separately.
    float3 zgGravel(float3 P, float3 d, float t, float px, texture2d<float, access::read> field, constant SkyU& u, constant GardenU& g) {
        float2 cp = zgCell(P.xy, g);
        float cell = g.bed.x, snow = g.c.x, wet = g.b.w;
        int oct = int(g.c.w + 0.5);
        float fx = t * px / cell, fy = fx / max(-d.z, 0.03);
        float ax = 1.0 - smoothstep(0.9, 2.1, fx), ay = 1.0 - smoothstep(0.9, 2.1, fy);
        float iso = min(ax, ay);
        float3 r = zgRelief(field, cp);
        float h = r.x * iso;
        // Snow lies level in the grooves, rising with the cover until it buries the ridges.
        float level = mix(-1.3, 0.8, snow);
        float bare = snow > 0.001 ? smoothstep(level - 0.06, level + 0.08, h) : 1.0;
        float relief = g.b.y * (1.0 - 0.35 * wet);
        float2 slope = float2(r.y * ax, -r.z * ay) * (relief / cell) * bare;
        float3 n = normalize(float3(-slope.x, -slope.y, 1.0));
        float shade = zgStoneShadow(P, -1, g) * zgWallShadow(P, g);
        float ridge = 1.0;
        if (g.key.z > 0.0 && iso > 0.01 && g.keyColor.r + g.keyColor.g > 0.002) {
            float2 lp = abs(g.key.xy);
            float aaS = mix(ax, ay, lp.y / max(lp.x + lp.y, 1e-4));
            ridge = mix(1.0, zgRidgeShadow(field, cp, level, g), aaS * bare);
        }
        float ao = 1.0 - 0.28 * saturate(-h * 1.4) * bare + 0.05 * saturate(h) * bare;
        // The gravel itself: crushed granite, white with grey grains (lost in the distance).
        float fine = 1.0 - smoothstep(0.003, 0.012, t * px);
        float grain = vnoise3(float3(P.xy * 90.0, 1.7));
        float speck = smoothstep(0.78, 0.95, hash13(float3(floor(P.xy * 140.0), 3.0)));
        float3 albedo = kGravel * (0.96 + 0.08 * vnoise3(float3(P.xy * 1.3, 4.0))) * (1.0 + fine * (0.12 * (grain - 0.5) - 0.16 * speck));
        albedo *= 1.0 - 0.42 * wet;
        albedo = mix(albedo, kSnow, saturate(1.0 - bare + 0.45 * snow));
        float3 col = albedo * (g.ambient.rgb * ao * (0.82 + 0.18 * n.z) + zgDirect(n, shade * ridge, g));
        if (wet > 0.01) {
            col += g.keyColor.rgb * (wet * 0.6 * zgSheen(dot(reflect(d, n), g.key.xyz)) * shade);
            col += mix(u.horizon.rgb, u.zenith.rgb, 0.5) * (wet * 0.06);
        }
        if (snow > 0.05) {
            float glint = smoothstep(0.93, 1.0, hash13(float3(floor(P.xy * 120.0), 9.0))) * fine * (1.0 - bare);
            col += g.keyColor.rgb * (glint * 0.8 * g.view.w * shade);
        }
        // The moss islands round the stones (wider with the Moss setting), velvet green, deepening in rain.
        float stone;
        float island = zgIsland(cp, g, stone);
        float reach = g.b.z;
        if (island < reach + 2.0) {
            float nm = fbm3(float3(P.xy * 7.0, 4.2), oct);
            float m = 1.0 - smoothstep(reach - 0.6, reach + 0.6, island + 2.2 * (nm - 0.5));
            if (m > 0.0) {
                float2 tuft = float2(vnoise3(float3(P.xy * 24.0, 1.0)), vnoise3(float3(P.xy * 24.0, 5.0))) - 0.5;
                float3 mn = normalize(float3(tuft * 0.6, 1.0));
                float3 moss = kMoss * (0.7 + 0.6 * nm) * (1.0 + 0.4 * wet);
                moss = mix(moss, kSnow, snow * 0.9);
                moss = mix(moss, float3(0.6, 0.66, 0.7), 0.25 * saturate(u.still.y));
                moss *= 0.55 + 0.45 * smoothstep(0.0, 2.5, stone);   // shaded at the stones' feet
                col = mix(col, moss * (g.ambient.rgb * 0.9 + zgDirect(mn, shade, g)), m);
            }
        }
        // A chord's wave: its two fronts sweep a soft light across the gravel.
        float wb = g.wave.w;
        if (wb > 0.001) {
            float ub = cp.x / 256.0, w = g.wave.z;
            float wa = (ub - g.wave.x) / w, wc = (ub - g.wave.y) / w;
            col += albedo * g.waveColor.rgb * (wb * 0.5 * (exp(-wa * wa) + exp(-wc * wc)));
        }
        // Held notes: the rake turning fresh gravel where it is on its ring.
        int nr = int(g.counts.x + 0.5);
        for (int i = 0; i < 12; i++) {
            if (i >= nr) break;
            float4 rk = g.rakes[i];
            float2 dq = cp - rk.xy;
            float e2 = dot(dq, dq);
            if (e2 > 64.0) continue;
            col += albedo * kRakeLight * (rk.w * 0.45 * exp(-e2 / 5.0));
        }
        return col;
    }

    /// The granite kerb round the bed: long slabs and their joints along `along` (m), lit flat.
    float3 zgKerb(float3 P, float along, constant SkyU& u, constant GardenU& g) {
        float j = fract(along / 0.85);
        float joint = smoothstep(0.0, 0.012, j) * (1.0 - smoothstep(0.988, 1.0, j));
        float3 stone = float3(0.33, 0.32, 0.30) * (0.88 + 0.2 * vnoise3(float3(P.xy * 9.0, 2.0))) * (0.55 + 0.45 * joint);
        stone *= 1.0 - 0.4 * g.b.w;
        stone = mix(stone, kSnow, 0.85 * g.c.x);
        float shade = zgStoneShadow(P, -1, g) * zgWallShadow(P, g);
        return stone * (g.ambient.rgb + zgDirect(float3(0.0, 0.0, 1.0), shade, g));
    }

    /// The moss banks either side of the bed (the maple's on the left, its fallen leaves under it as the canopy thins).
    float3 zgBank(float3 P, constant SkyU& u, constant GardenU& g) {
        int oct = int(g.c.w + 0.5);
        float nm = fbm3(float3(P.xy * 3.0, 6.1), oct);
        float3 moss = kMoss * (0.6 + 0.7 * nm) * (1.0 + 0.35 * g.b.w);
        float fall = saturate(1.1 - g.maple.w);
        if (fall > 0.0) {
            float2 dm = P.xy - float2(g.mapleAt.x + 1.1, g.mapleAt.y - 0.5);
            float leaf = smoothstep(0.62, 0.8, vnoise3(float3(P.xy * 26.0, 3.3)));
            moss = mix(moss, g.maple.rgb * 0.8, leaf * exp(-dot(dm, dm) / 5.0) * fall);
        }
        moss = mix(moss, kSnow, g.c.x);
        moss = mix(moss, float3(0.55, 0.6, 0.64), 0.3 * saturate(u.still.y));
        float shade = zgStoneShadow(P, -1, g) * zgWallShadow(P, g);
        return moss * (g.ambient.rgb * 0.9 + zgDirect(float3(0.0, 0.0, 1.0), shade, g));
    }

    /// The drip line below the veranda: dark river pebbles, moss creeping round the basin, the knocker's shade at its foot.
    float3 zgStrip(float3 P, float t, float px, constant SkyU& u, constant GardenU& g) {
        float2 cq = P.xy / 0.075;
        float2 i0 = floor(cq);
        float best = 9.0;
        float2 off = float2(0.0);
        float3 hb = float3(0.0);
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 c = i0 + float2(float(i), float(j));
                float3 h = hash33(float3(c, 5.0));
                float2 o2 = cq - (c + 0.15 + 0.7 * h.xy);
                float dd = dot(o2, o2);
                if (dd < best) { best = dd; off = o2; hb = h; }
            }
        }
        float rr = sqrt(best) / 0.6;
        float dome = sqrt(saturate(1.0 - rr * rr));
        float3 n = normalize(float3(off * 1.3, 0.25 + dome));
        float3 pebble = mix(float3(0.035, 0.038, 0.042), float3(0.13, 0.125, 0.12), hb.z);
        pebble *= 1.0 - 0.6 * smoothstep(0.8, 1.05, rr);
        float wet = g.b.w;
        pebble *= 1.0 - 0.35 * wet;
        // Moss round the basin.
        float2 db = (P.xy - float2(g.knockerAt.x - 0.62, g.knockerAt.y)) / float2(0.9, 0.35);
        float moss = (1.0 - smoothstep(0.6, 1.0, length(db) + 0.4 * (vnoise3(float3(P.xy * 6.0, 2.0)) - 0.5))) * 0.85;
        float3 base = mix(pebble, kMoss * 0.8, moss);
        base = mix(base, kSnow, g.c.x * 0.95);
        float shade = zgStoneShadow(P, -1, g);
        float2 dk = (P.xy - float2(g.knockerAt.x - 0.25, g.knockerAt.y)) / float2(0.75, 0.22);
        float foot = 1.0 - 0.55 * exp(-dot(dk, dk));
        float3 col = base * (g.ambient.rgb * foot + zgDirect(n, shade * foot, g));
        if (wet > 0.01) col += g.keyColor.rgb * (wet * 0.7 * zgSheen(dot(reflect(float3(0.0, 0.0, -1.0), n), g.key.xyz)) * shade);
        return col;
    }

    // ---------------------------------------------------------------- the wall and its cap
    /// The low earthen wall's face and its tiled cap at q = (x, z) on the face (m), met along d at distance t: rammed
    /// earth in layers, darkened in clouds by its oils, streaked under the cap and damp at its foot; the cap's round tile
    /// ends, the tiles and the ridge (snow in the channels, rime on the edges).
    float3 zgWall(float2 q, float3 d, float t, constant SkyU& u, constant GardenU& g) {
        float hw = g.wall.x, cap = g.wall.y;
        int oct = int(g.c.w + 0.5);
        float shade = zgStoneShadow(float3(q.x, g.bed.z, q.y), -1, g);
        if (q.y < hw) {
            // Rammed earth in faint layers, its oils seeping out in soft clouds, streaked under the cap, damp at its foot.
            float band = q.y / 0.16 + 0.35 * vnoise3(float3(q.x * 0.45, 2.0, 0.3));
            float bf = fract(band);
            float3 earth = float3(0.56, 0.42, 0.27) * (0.94 + 0.08 * hash13(float3(floor(band), 7.0, 3.0)));
            earth *= 0.95 + 0.05 * smoothstep(0.0, 0.12, bf) * (1.0 - smoothstep(0.88, 1.0, bf));
            float stain = fbm3(float3(q.x * 0.32, q.y * 0.55, 5.0), oct);
            earth = mix(earth, float3(0.36, 0.26, 0.17), 0.55 * smoothstep(0.48, 0.8, stain));
            float streak = vnoise3(float3(q.x * 5.0, q.y * 0.4, 9.0));
            earth *= 1.0 - 0.12 * smoothstep(0.55, 0.9, streak) * smoothstep(hw - 0.8, hw - 0.1, q.y);
            earth *= 1.0 - 0.28 * (1.0 - smoothstep(0.0, 0.18, q.y)) * (1.0 + g.b.w);
            earth *= 1.0 - 0.3 * g.b.w;
            float eave = smoothstep(hw - 0.14, hw - 0.01, q.y);
            // Light: the sky, the sun when it is behind the eye, and the white gravel's light thrown back up at it.
            float3 ground = mix(kGravel * (1.0 - 0.42 * g.b.w), kSnow, g.c.x);
            float3 bounce = ground * (g.ambient.rgb + g.keyColor.rgb * (0.8 * max(g.key.z, 0.0))) * 0.26;
            return earth * ((g.ambient.rgb * 0.8 + bounce) * (1.0 - 0.45 * eave)
                            + zgDirect(float3(0.0, -1.0, 0.0), shade * (1.0 - 0.9 * eave), g));
        }
        float cz = q.y - hw;
        float lx = fract(q.x / 0.16);
        float3 tile = float3(0.105, 0.105, 0.115);
        float3 n;
        if (cz < 0.07) {
            float2 dd = float2((lx - 0.5) * 0.16, cz - 0.036);
            float disc = 1.0 - smoothstep(0.024, 0.03, length(dd));
            n = normalize(float3(0.0, -1.0, 0.25));
            tile *= 0.75 + 0.45 * disc;
        } else if (cz < cap - 0.07) {
            float s = sin(6.2831853 * lx), cc = cos(6.2831853 * lx);
            n = normalize(float3(0.55 * s, -0.45, 0.75 + 0.2 * cc));
            tile *= 0.85 + 0.25 * cc;
            float channel = 1.0 - smoothstep(-0.5, 0.1, cc);
            tile = mix(tile, kSnow, g.c.x * (0.6 + 0.4 * channel));
        } else {
            float k = (cz - (cap - 0.07)) / 0.07;
            n = normalize(float3(0.0, -0.4, 0.6 + 0.5 * k));
            tile *= 0.9 + 0.3 * smoothstep(0.6, 1.0, k);
            tile = mix(tile, kSnow, g.c.x * 0.9 * smoothstep(0.2, 0.9, k));
        }
        tile *= 1.0 - 0.25 * g.b.w;
        float3 col = tile * (g.ambient.rgb * 0.9 + zgDirect(n, shade, g));
        if (g.b.w > 0.01) col += g.keyColor.rgb * (g.b.w * 0.4 * zgSheen(dot(reflect(d, n), g.key.xyz)));
        float tv = t * u.up.w;
        float2 rp = q / tv;
        float rime = max(rimeEdge(u, (hw + cap - q.y) / tv, float2(0.0, 1.0), rp),
                         rimeEdge(u, cz / tv, float2(0.0, -1.0), rp + 7.0));
        return mix(col, rimeColor(u), rime);
    }

    // ---------------------------------------------------------------- beyond the wall
    /// The temple grounds' trees beyond the wall (a dark line of rounded crowns) and, far behind them, the tall cedar
    /// rising out of them (a narrow spire of dense, tufted sprays), along d (garden frame) from the eye: their cover of
    /// the pixel, premultiplied colour (backlit edges glowing, rime on their outlines, snow on the crowns) and distance.
    float zgFar(float3 d, float px, constant SkyU& u, constant GardenU& g, thread float3& col, thread float& dist) {
        col = float3(0.0);
        dist = 1e9;
        if (d.y <= 1e-4) return 0.0;
        float eye = g.a.z, tanV = u.up.w;
        int oct = int(g.c.w + 0.5);
        float back = saturate(dot(d, g.key.xyz));
        float back2 = back * back, back8 = back2 * back2;
        back8 *= back8;
        float cover = 0.0;
        float3 snowLit = kSnow * (g.ambient.rgb * 1.1 + g.keyColor.rgb * 0.4);
        float tc = g.cedarAt.y / d.y;
        float2 qc = float2(d.x * tc, eye + d.z * tc);
        float pc = tc * px;
        float below = g.cedarAt.z - qc.y;
        if (below > -pc) {
            float sway = g.cedarAt.w * saturate(1.0 - below / 5.0);
            float dx = qc.x - (g.cedarAt.x + sway);
            float side = dx < 0.0 ? -1.0 : 1.0;
            float b = max(below, 0.0);
            float tufts = vnoise3(float3(qc.y * 1.3, side * 3.0, 2.0)) + 0.5 * vnoise3(float3(qc.y * 3.1, side * 5.0, 4.0));
            float hw = min(0.16 * sqrt(b * (b + 0.8)), 2.1) * (0.66 + 0.42 * tufts);
            float inside = hw - abs(dx);
            float cedar = saturate(inside / pc + 0.5) * saturate(below / pc + 0.5);
            if (cedar > 0.0) {
                float spray = vnoise3(float3(qc * 2.4, 6.0));
                float3 needle = float3(0.016, 0.03, 0.024) * (0.65 + 0.6 * spray);
                float3 c = needle * (g.ambient.rgb * 1.1 + zgDirect(float3(0.5 * side, -0.5, 0.7), 1.0, g) * 0.5);
                c += g.keyColor.rgb * (0.22 * exp(-max(inside, 0.0) / 0.2) * back8);
                c = mix(c, snowLit, g.c.x * (0.16 + 0.16 * spray));
                c = mix(c, rimeColor(u), rimeEdge(u, inside / (tc * tanV), float2(side, 0.2), qc / (tc * tanV)));
                col = zgHaze(c, tc, u, g) * cedar;
                cover = cedar;
                if (cedar > 0.5) dist = tc;
            }
        }
        float tb = (g.bed.z + 24.0) / d.y;
        float2 qb = float2(d.x * tb, eye + d.z * tb);
        float pb = tb * px;
        if (qb.y > 7.7 + pb) return cover;   // above the tallest crown (3.4 + 2 + 1.9 + 0.2 m): open sky, or the cedar
        // Rounded crowns along the tree line: each cell of it holds a crown of its own size, over a slow rise and fall.
        float top = 3.4 + 2.0 * fbm3(float3(qb.x * 0.07, 3.7, 1.1), oct);
        float ci = floor(qb.x / 3.4);
        float crowns = 0.0, crownX = 0.0;
        for (int k = -1; k <= 1; k++) {
            float cx = ci + float(k);
            float3 h = hash33(float3(cx, 4.0, 9.0));
            float rc = 1.5 + 1.2 * h.y;
            float x = (qb.x - (cx + 0.2 + 0.6 * h.x) * 3.4) / rc;
            float crown = (0.6 + 1.3 * h.z) * sqrt(saturate(1.0 - x * x));
            if (crown > crowns) { crowns = crown; crownX = clamp(x, -1.0, 1.0); }
        }
        top += crowns + 0.35 * (vnoise3(float3(qb.x * 1.7, qb.y * 1.7, 0.4)) - 0.5);
        float trees = saturate((top - qb.y) / pb + 0.5);
        if (trees > 0.0) {
            float under = top - qb.y;
            float leafN = vnoise3(float3(qb * 1.3, 2.0)), leafF = vnoise3(float3(qb * 4.1, 5.0));
            float3 leaf = float3(0.034, 0.06, 0.034) * (0.55 + 0.55 * leafN + 0.3 * leafF) * (0.7 + 0.3 * saturate(1.0 - under / 3.0));
            float crownTop = saturate(1.0 - under / 1.6);   // a crown's own roundness shows near its top, then the mass
            float3 cn = normalize(float3(0.75 * crownX * crownTop + 0.3 * (leafN - 0.5), -0.6, 0.4 + 0.5 * crownTop));
            float3 c = leaf * (g.ambient.rgb * 1.1 + zgDirect(cn, 1.0, g) * 0.6);
            c += g.keyColor.rgb * (0.2 * exp(-max(under, 0.0) / 0.3) * back8);
            c = mix(c, snowLit, g.c.x * (0.18 + 0.32 * crownTop) * (0.55 + 0.45 * leafN));
            c = mix(c, rimeColor(u), rimeEdge(u, under / (tb * tanV), float2(0.0, 1.0), qb / (tb * tanV)));
            col = zgHaze(c, tb, u, g) * trees + col * (1.0 - trees);
            cover = trees + cover * (1.0 - trees);
            if (trees > 0.5) dist = tb;
        }
        return cover;
    }

    // ---------------------------------------------------------------- the maple
    /// The maple on the left bank (spec §9.1): a twisting trunk and its layered tiers of leaves in the season's colour,
    /// thinning as the canopy does (its bare branches show), glowing when the light is behind it, swaying a little;
    /// q = (x, z) in its plane (m), `pm` a pixel there (m), t its distance. Returns its cover, writes its colour.
    float zgMaple(float2 q, float pm, float3 d, float t, constant SkyU& u, constant GardenU& g, thread float3& col) {
        col = float3(0.0);
        float x0 = g.mapleAt.x, sway = g.mapleAt.z;
        if (q.x < x0 - 1.6 || q.x > x0 + 4.0 || q.y < -0.05 || q.y > 3.8) return 0.0;
        int oct = min(int(g.c.w + 0.5), 2);
        float leaves = g.maple.w, snow = g.c.x;
        float tv = t * u.up.w;
        // The trunk, leaning out over the bed, and its limbs into the tiers.
        float2 b0 = float2(x0, -0.05), b1 = float2(x0 + 0.24, 0.9), b2 = float2(x0 + 0.1 + 0.3 * sway, 1.5);
        float2 s1 = zgSeg(q, b0, b1), s2 = zgSeg(q, b1, b2);
        float bark = 0.11 - 0.03 * s1.y - s1.x;
        float2 bOut = q - mix(b0, b1, s1.y);
        if (0.08 - 0.02 * s2.y - s2.x > bark) { bark = 0.08 - 0.02 * s2.y - s2.x; bOut = q - mix(b1, b2, s2.y); }
        for (int k = 0; k < 4; k++) {
            float4 tr = kMapleTiers[k];
            float rise = tr.y / 3.2;
            float2 c = float2(x0 + tr.x * 0.8 + sway * rise * rise, tr.y - 0.12);
            float2 sl = zgSeg(q, k < 2 ? b1 : b2, c);
            float e = 0.05 - 0.025 * sl.y - sl.x;
            if (e > bark) { bark = e; bOut = q - mix(k < 2 ? b1 : b2, c, sl.y); }
        }
        float barkCover = saturate(bark / pm + 0.5);
        // The tiers of leaves: lacy at their edges and holed through (more as the canopy thins), lighter on top.
        float leaf = 0.0, inside = -1.0, clumpAt = 0.5, upAt = 0.0;
        float2 outward = float2(0.0, 1.0);
        float thr = mix(1.05, 0.4, leaves);
        for (int k = 0; k < 4; k++) {
            float4 tr = kMapleTiers[k];
            float rise = tr.y / 3.2;
            float2 c = float2(x0 + tr.x + sway * rise * rise, tr.y);
            float2 dq = (q - c) / tr.zw;
            float l = length(dq);
            if (l > 1.4) continue;
            float clump = fbm3(float3(q * 6.5, 1.5 + float(k)), oct);
            float fineN = vnoise3(float3(q * 19.0, 7.0 + float(k)));
            float e = (1.0 - l) * tr.w + 0.24 * (clump - 0.5) + 0.07 * (fineN - 0.5);
            float keep = smoothstep(thr, thr + 0.16, clump + 0.15 * fineN + 0.3 * (1.0 - l));
            float a = saturate(e / pm + 0.5) * keep;
            if (a > leaf) { leaf = a; inside = e; outward = dq / max(l, 1e-4); clumpAt = clump; upAt = dq.y; }
        }
        float cover = max(leaf, barkCover);
        if (cover <= 0.0) return 0.0;
        float3 L = g.key.xyz;
        float back = saturate(dot(d, L));
        float back2 = back * back, back4 = back2 * back2;
        float3 ln = normalize(float3(outward.x * 0.55, -0.55, 0.35 + 0.6 * outward.y));
        float self = 0.6 + 0.4 * smoothstep(-0.9, 0.7, upAt + 0.5 * (clumpAt - 0.5));   // a tier's underside in its own shade
        float3 alb = g.maple.rgb * (0.3 + 0.4 * clumpAt);
        float3 lit = alb * (g.ambient.rgb * (0.8 * self) + zgDirect(ln, self, g) * 0.9);
        lit += alb * g.keyColor.rgb * (0.8 * back4 * (0.4 + 0.6 * leaves));              // the light through the leaves
        lit = mix(lit, kSnow * (g.ambient.rgb + zgDirect(float3(0.0, 0.0, 1.0), 1.0, g)), snow * smoothstep(0.2, 0.8, outward.y) * 0.85);
        lit = mix(lit, rimeColor(u), rimeEdge(u, inside / tv, outward, q / tv));
        float3 wood = float3(0.055, 0.042, 0.034) * (g.ambient.rgb * 0.9 + zgDirect(normalize(float3(bOut.x * 12.0, -0.6, bOut.y * 12.0)), 1.0, g) * 0.6);
        wood = mix(wood, rimeColor(u), rimeEdge(u, bark / tv, bOut, q / tv + 3.0));
        col = mix(wood, lit, leaf / max(cover, 1e-4));
        return cover;
    }

    // ---------------------------------------------------------------- the water-knocker
    /// One length of bamboo from a to b, `r` thick (m): its cover and colour, rounded in the light, darker at its nodes
    /// every `node` metres.
    float zgBamboo(float2 q, float2 a, float2 b, float r, float node, float pm, constant GardenU& g, thread float3& col) {
        float2 s = zgSeg(q, a, b);
        float cover = saturate((r - s.x) / pm + 0.5);
        if (cover <= 0.0) return 0.0;
        float2 ab = b - a;
        float len = length(ab);
        float2 axis = ab / max(len, 1e-5), perp = float2(-axis.y, axis.x);
        float across = clamp(dot(q - a, perp) / r, -1.0, 1.0);
        float2 rim = perp * across;   // in the plane (x, z); the rest of the normal faces the eye (−y)
        float3 n = normalize(float3(rim.x, -sqrt(saturate(1.0 - across * across)), rim.y));
        float at = fract(s.y * len / node + 0.37);
        float ring = 1.0 - 0.45 * (1.0 - smoothstep(0.0, 0.05, at)) - 0.45 * smoothstep(0.95, 1.0, at);
        float3 base = kBamboo * ring * (1.0 - 0.3 * g.b.w);
        base = mix(base, kSnow, g.c.x * 0.8 * saturate(n.z));
        col = base * (g.ambient.rgb * 0.8 + zgDirect(n, 1.0, g));
        col += g.keyColor.rgb * (0.25 * zgSheen(dot(n, normalize(g.key.xyz + float3(0.0, -1.0, 0.001)))));   // never a zero half-vector
        return cover;
    }

    /// The bamboo water-knocker by its stone basin (spec §9.1), in its plane: q = (x, z) (m), `pm` a pixel there (m),
    /// d the ray. The spout trickles into the tube's mouth; full, it tips and pours into the basin, swings back and clacks
    /// on its stone (the water in the basin rings). Returns its cover, writes its colour.
    float zgKnocker(float2 q, float pm, float3 d, constant SkyU& u, constant GardenU& g, thread float3& col) {
        col = float3(0.0);
        float x0 = g.knockerAt.x;
        if (q.x < x0 - 1.05 || q.x > x0 + 1.7 || q.y < -0.02 || q.y > 1.0) return 0.0;
        float2 pivot = float2(x0, 0.42);
        float ang = g.knocker.x;
        float2 axis = float2(-cos(ang), sin(ang));                 // pivot → mouth
        float2 mouth = pivot + axis * 0.5, butt = pivot - axis * 0.28;
        float look = saturate(-d.z);                               // how far down we look: the basin's top shows
        float time = g.view.z;
        float cover = 0.0;
        // The basin: a rough round stone with a hollow of water in its top.
        float bx = x0 - 0.62, bw = 0.3, bh = 0.27;
        float ry = bw * look * 0.95;
        float2 tq = float2((q.x - bx) / bw, (q.y - bh) / max(ry, 1e-3));
        float rough = 0.025 * (vnoise3(float3(q * 11.0, 1.0)) - 0.5);
        float girth = bw * (0.84 + 0.16 * sin(3.14159 * saturate(q.y / bh)));   // fuller in the middle, a natural stone
        float side = max(abs(q.x - bx) - girth - rough, max(-q.y, q.y - bh - rough));
        float topE = length(tq) - 1.0 - rough / bw;
        float body = saturate(-side / pm + 0.5);
        float topCover = saturate(-topE * min(bw, ry) / pm + 0.5);
        float basin = max(body, topCover);
        if (basin > 0.0) {
            float nb = fbm3(float3(q * 9.0, 7.0), 2);
            float3 stone = float3(0.2, 0.21, 0.19) * (0.7 + 0.6 * nb) * (1.0 - 0.4 * g.b.w);
            stone = mix(stone, kMoss * 0.9, 0.6 * (1.0 - smoothstep(0.02, 0.16, q.y)) * smoothstep(0.4, 0.6, nb));
            float sx = clamp((q.x - bx) / bw, -1.0, 1.0);
            float3 n = topCover > body ? float3(0.0, 0.0, 1.0) : normalize(float3(sx, -sqrt(saturate(1.0 - sx * sx)), 0.05));
            float3 c = mix(stone, kSnow, g.c.x * (topCover > body ? 0.9 : 0.2));
            c *= g.ambient.rgb * 0.85 + zgDirect(n, 1.0, g);
            // The water in its hollow, mirroring the sky, ringing when the pour lands or the tube clacks.
            float wr = length(tq / 0.66);
            if (topCover > 0.0 && wr < 1.0) {
                float2 land = float2((mouth.x - 0.04 - bx) / bw, 0.0);
                float rd = length(float2(tq.x - land.x, tq.y) * float2(1.0, 0.7));
                float ripple = sin(rd * 26.0 - time * 9.0) * exp(-rd * 3.0) * (g.knocker.z + 0.6 * g.knocker.w);
                float3 water = mix(u.zenith.rgb, u.horizon.rgb, 0.6) * 0.34 + float3(0.006, 0.01, 0.012);
                water += g.keyColor.rgb * (0.25 * saturate(ripple)) + u.horizon.rgb * (0.12 * saturate(ripple));
                water = mix(water, kSnow * 0.8 * g.ambient.rgb * 2.0, 0.6 * g.c.x * g.c.x);
                c = mix(c, water, (1.0 - smoothstep(0.86, 1.0, wr)) * topCover);
            }
            col = c;
            cover = basin;
        }
        // The stone the tube clacks on.
        float2 cs = (q - float2(x0 + 0.3, 0.035)) / float2(0.14, 0.075);
        float clackStone = saturate((1.0 - length(cs) + 0.12 * (vnoise3(float3(q * 18.0, 3.0)) - 0.5)) * 0.07 / pm + 0.5) * step(0.0, q.y);
        if (clackStone > 0.0) {
            float3 c = float3(0.09, 0.09, 0.095) * (0.8 + 0.4 * vnoise3(float3(q * 14.0, 3.0)));
            c = mix(c, kSnow, g.c.x * 0.8 * saturate(cs.y + 0.3));
            c *= g.ambient.rgb * 0.85 + zgDirect(normalize(float3(cs.x, -0.6, cs.y + 0.5)), 1.0, g);
            col = mix(col, c, clackStone);
            cover = max(cover, clackStone);
        }
        float3 bc;
        // The back post, the tube on its pivot, the front post, the spout and its post.
        float a = zgBamboo(q, float2(x0 + 0.03, 0.0), float2(x0 + 0.03, 0.5), 0.02, 0.24, pm, g, bc);
        if (a > 0.0) { col = mix(col, bc * 0.7, a); cover = max(cover, a); }
        a = zgBamboo(q, butt, mouth, 0.034, 0.26, pm, g, bc);
        if (a > 0.0) {
            // The mouth's slant cut shows the dark hollow inside.
            float2 s = zgSeg(q, butt, mouth);
            float hollow = smoothstep(0.9, 0.96, s.y) * (1.0 - smoothstep(0.5, 0.95, s.x / 0.034));
            col = mix(col, mix(bc, float3(0.02, 0.022, 0.012), 0.8 * hollow), a);
            cover = max(cover, a);
        }
        a = zgBamboo(q, float2(x0 - 0.02, 0.0), float2(x0 - 0.02, 0.47), 0.021, 0.24, pm, g, bc);
        if (a > 0.0) { col = mix(col, bc, a); cover = max(cover, a); }
        float pin = saturate((0.012 - length(q - pivot)) / pm + 0.5);
        if (pin > 0.0) { col = mix(col, float3(0.02, 0.018, 0.015), pin); }
        float2 spoutTip = float2(x0 - 0.45, 0.8);
        a = zgBamboo(q, spoutTip, float2(x0 + 1.75, 0.86), 0.017, 0.4, pm, g, bc);
        if (a > 0.0) {
            float open = (1.0 - smoothstep(0.012, 0.03, q.x - spoutTip.x)) * 0.7;
            col = mix(col, mix(bc, float3(0.02, 0.02, 0.01), open), a);
            cover = max(cover, a);
        }
        a = zgBamboo(q, float2(x0 + 1.05, 0.0), float2(x0 + 1.05, 0.88), 0.024, 0.3, pm, g, bc);
        if (a > 0.0) { col = mix(col, bc * 0.9, a); cover = max(cover, a); }
        // Water: the spout's thin stream (into the mouth while it waits under it), and the pour into the basin.
        float3 waterLight = u.horizon.rgb * 0.9 + g.keyColor.rgb * 0.35;
        float under = 1.0 - smoothstep(0.03, 0.07, abs(mouth.x - spoutTip.x));
        float streamEnd = mix(bh, mouth.y + 0.03, under);
        if (q.y < spoutTip.y && q.y > streamEnd) {
            float wob = 0.002 * sin(q.y * 80.0 - time * 14.0);
            float s = saturate((0.0035 + 0.5 * pm - abs(q.x - spoutTip.x - wob)) / pm) * min(1.0, 0.007 / pm);
            col = mix(col, waterLight, 0.75 * s);
            cover = max(cover, 0.75 * s);
        }
        float pour = g.knocker.z;
        if (pour > 0.01) {
            float2 lip = mouth + axis * 0.02;
            float2 sp = zgSeg(q, lip, float2(lip.x - 0.06, bh - 0.01));
            float s = saturate((0.006 * pour + 0.5 * pm - sp.x) / pm) * min(1.0, 0.012 / pm);
            col = mix(col, waterLight, 0.8 * s * pour);
            cover = max(cover, 0.8 * s * pour);
        }
        return cover;
    }

    // ---------------------------------------------------------------- the frame
    fragment ColorDepth garden_fragment(GardenOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant GardenU& g [[buffer(1)]],
                                        texture2d<float> stars [[texture(0)]], texture2d<float, access::read> field [[texture(1)]]) {
        ColorDepth out;
        float2 p = in.ndc;
        if (p.y < g.a.x) {   // under the keyboard
            out.color = float4(0, 0, 0, 1); out.depth = float4(0.1, 0, 0, 1);
            return out;
        }
        float3 dw = normalize(u.forward.xyz + u.right.xyz * p.x * u.right.w + u.up.xyz * p.y * u.up.w);   // east-north-up
        float2 fwd = g.view.xy, rgt = float2(fwd.y, -fwd.x);
        float3 d = float3(dot(dw.xy, rgt), dot(dw.xy, fwd), dw.z);                                         // the garden's
        float px = u.weather.w;
        float eye = g.a.z;
        float3 o = float3(0.0, 0.0, eye);
        float near = g.bed.y, kerbW = g.bed.w, halfW = 128.0 * g.bed.x;
        float capTop = g.wall.x + g.wall.y;
        float tG = d.z < -1e-5 ? eye / -d.z : 1e9;
        float tW = d.y > 1e-5 ? g.bed.z / d.y : 1e9;
        float3 col = float3(0.0);
        float tBack = 1e9;
        bool farSky = false;
        float farCover = 1.0;
        if (tG < tW) {
            // The ground before the wall: the drip line, the kerb, the gravel and its moss, the banks.
            float3 P = o + d * tG;
            tBack = tG;
            float ax = abs(P.x);
            if (P.y < near - kerbW) col = zgStrip(P, tG, px, u, g);
            else if (P.y < near) col = zgKerb(P, P.x, u, g);
            else if (ax < halfW) col = zgGravel(P, d, tG, px, field, u, g);
            else if (ax < halfW + kerbW) col = zgKerb(P, P.y, u, g);
            else col = zgBank(P, u, g);
            col = zgHaze(col, tG, u, g);
        } else if (tW < 1e8 && eye + d.z * tW <= capTop) {
            tBack = tW;
            col = zgHaze(zgWall(float2(d.x * tW, eye + d.z * tW), d, tW, u, g), tW, u, g);
        } else {
            float fd;
            farCover = zgFar(d, px, u, g, col, fd);
            farSky = true;
            if (farCover > 0.5) tBack = fd;
        }
        float depth = saturate(tBack / 40.0);

        // The maple, when its plane comes before whatever lies behind it.
        float mapleCover = 0.0;
        float3 mapleCol = float3(0.0);
        float tm = d.y > 1e-5 ? g.mapleAt.y / d.y : 1e9;
        if (tm < tBack) mapleCover = zgMaple(float2(d.x * tm, eye + d.z * tm), tm * px, d, tm, u, g, mapleCol);
        if (farSky) {
            if (farCover < 0.002 && mapleCover < 0.002) {   // only sky here: the dome shows
                discard_fragment();
                out.color = float4(0, 0, 0, 1); out.depth = float4(1, 0, 0, 1);
                return out;
            }
            if (farCover < 0.999) {
                float mm;
                col += skyRadiance(dw, u, mm, stars) * (1.0 - farCover);
            }
        }
        if (mapleCover > 0.0) {
            col = mix(col, zgHaze(mapleCol, tm, u, g), mapleCover);
            if (mapleCover > 0.5) depth = saturate(tm / 40.0);
        }

        // The stones, in front of the ground, the wall and the maple behind them.
        float tNear = tBack;
        for (int i = 0; i < 5; i++) {
            float ts = 0.0, inside = 0.0;
            float3 sn = float3(0.0, 0.0, 1.0);
            float cov = zgStone(i, o, d, px, g, ts, sn, inside);
            if (cov <= 0.0 || ts >= tNear) continue;
            col = mix(col, zgHaze(zgStoneColor(i, o + d * ts, sn, d, ts, inside, u, g), ts, u, g), cov);
            if (cov > 0.5) { tNear = ts; depth = saturate(ts / 40.0); }
        }

        // The water-knocker and its basin, nearest of all.
        float tk = d.y > 1e-5 ? g.knockerAt.y / d.y : 1e9;
        if (tk < tNear) {
            float3 kc;
            float kcov = zgKnocker(float2(d.x * tk, eye + d.z * tk), tk * px, d, u, g, kc);
            if (kcov > 0.0) {
                col = mix(col, zgHaze(kc, tk, u, g), kcov);
                if (kcov > 0.5) depth = saturate(tk / 40.0);
            }
        }
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, light).
    struct GardenKey { float4 rect; float4 info; };
    struct GardenKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex GardenKeyOut garden_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant GardenKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        GardenKey k = keys[iid];
        GardenKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    /// Keys of pale cypress along the veranda's edge (the black keys dark wood), pale gold where you play.
    fragment ColorDepth garden_keys_fragment(GardenKeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.018, 0.013, 0.01) : float3(0.15, 0.12, 0.085);
        float grain = 0.93 + 0.07 * sin(in.uv.y * 38.0 + 3.0 * sin(in.uv.x * 2.0 + in.uv.y * 5.0));
        float y2 = in.uv.y * in.uv.y;
        float sheen = y2 * y2 * y2 * (black ? 0.05 : 0.1) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * (1.0 - smoothstep(0.94, 1.0, in.uv.x));
        float3 c = base * grain * (0.35 + 0.65 * light) + float3(1.0, 0.92, 0.8) * (sheen * (0.3 + light))
                 + float3(1.0, 0.82, 0.5) * (glow * 1.5 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.1, 0, 0, 1);
        return o;
    }
    """
}
