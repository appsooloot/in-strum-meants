/// Metal source for Tea House Snow: kneeling at a low table in a small tea room, facing the paper screens.
/// The garden through the opening (drawn only there, over the Living Sky): the veranda's polished boards, a stone basin
/// with its bamboo ladle, a snow-viewing lantern capped with snow (its candle lit from dusk), a plum tree in a few red
/// blossoms, a pine bent under its snow, a low bamboo fence, snowy cedars beyond, and the snow; fog whitens it away
/// with distance, rime feathers the pine and the fence. The paper glows with the sky's light (the Window Kit draws its
/// kumiko and, for Frost Grow, its ice). The room: tatami with their dark borders, the lattice's light and shadow across
/// them, the alcove with its hanging scroll (an ensō: an abstract brush stroke, no characters) and a camellia, the
/// posts, the lintel and the sill, the low table, the tea bowl and the iron kettle on its brazier. Steam Lines: the
/// tea's ribbons of steam, the wisps your notes send curling off them and a chord's puff. Built on SkyShaders.common.
/// Smooth rules: no ray marching, ≤ 2 noise octaves per surface, every silhouette analytic, the wisps capped (12 on
/// Smooth); no pow(): squares and powers are written out.
enum TeaHouseSnowShaders {
    static let source = SkyShaders.common + """
    struct TeaU {
        float4 a;          // keys top (NDC y), aspect, horizon (NDC y: the garden's horizon and the room's eye level), time (s, wrapped)
        float4 room;       // sill (NDC y: the screens' foot), lintel (their head), the low table's far edge (NDC y), the alcove's right edge (screen units)
        float4 span;       // the screens' span left, right (screen units: NDC x × aspect), a panel's stile (screen units), how far open 0…1
        float4 b;          // night 0…1, day 0…1, noise octaves (2 Smooth, 3 above), sparkle scale (gentle visuals halve it)
        float4 paper;      // the paper's glow rgb (the sky's light through it and the room's on it), Frost Grow on (0/1)
        float4 inside;     // the room's own light rgb (from the paper, the opening and the brazier), unused
        float4 open;       // the opening's light rgb (the sky and the snow garden), unused
        float4 sun;        // the light through the screens in room space (x right, y up, z out to the garden), how direct 0…1
        float4 sunCol;     // the sun's colour (its strength is sun.w), unused
        float4 fire;       // the brazier's coals rgb, flicker 0…1
        float4 candle;     // the stone lantern's candle rgb (× how lit), flicker 0…1
        float4 c;          // mist 0…1, wind 0…1, snow 0…1, cloud 0…1
        float4 d;          // plum blossom 0…1, steam glow (after the flash limiter), chord puff (× sparkle), wisp count
        float4 bowl;       // the tea bowl's centre x (screen units), rim (NDC y), half width (screen units), the steam's height (NDC y units)
        float4 puff;       // the chord's puff: x (screen units), warmth 0…1 (1 major, 0 minor), strength 0…1 (× sparkle), age (s)
        float4 flake;      // the lantern's flake: x along its cap 0…1, age (s), velocity 0.85…1, falling (0/1)
        float4 e;          // ribbons 2…4, kumiko bar count, the brazier's centre x (screen units), its rim (NDC y)
        float4 path[3];    // the ribbon's 12 lateral offsets (−1…1), index 0 at the bowl
        float4 bars[12];   // a panel's kumiko (the Window Kit's bars): lo, hi (window coordinates), kind (0 vertical, 1 horizontal)
        float4 wisp[24];   // base x (screen units), rise 0…1 (of the steam's height), curl −1…1, brightness (× sparkle)
        float4 wispB[24];  // age (s), height 0…1, held (0/1), seed 0…1
    };
    struct TeaOut { float4 pos [[position]]; float2 ndc; };

    constant float2 teaQuad[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
    constant float kZWall = 3.6;          // the screens' plane from the eye (m)
    constant float kEyeGarden = 1.25;     // the eye above the garden's snow (m): kneeling on a floor raised over it
    constant float kAlcoveDepth = 0.75;   // how far the alcove reaches behind the screens' plane (m)
    constant float3 kCandle = float3(1.0, 0.64, 0.30);
    constant float3 kSnow = float3(0.93, 0.95, 1.0);
    constant float3 kInk = float3(0.045, 0.04, 0.038);

    // ---------------------------------------------------------------- small helpers
    float teaH1(float x) { return fract(sin(x * 127.1 + 311.7) * 43758.5453); }
    float teaH2(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }
    float teaN1(float x) {
        float i = floor(x), f = fract(x);
        float s = f * f * (3.0 - 2.0 * f);
        return mix(teaH1(i), teaH1(i + 1.0), s);
    }
    float teaN2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 s = f * f * (3.0 - 2.0 * f);
        return mix(mix(teaH2(i), teaH2(i + float2(1, 0)), s.x), mix(teaH2(i + float2(0, 1)), teaH2(i + float2(1, 1)), s.x), s.y);
    }
    /// Two octaves of value noise (the most any surface here uses).
    float teaF2(float2 p) {
        return teaN2(p) * 0.65 + teaN2(p * 2.07 + float2(5.3, 1.7)) * 0.35;
    }
    /// Distance from p to segment ab, and how far along it (0…1) the nearest point lies.
    float2 teaSeg(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
        return float2(length(pa - ba * h), h);
    }
    /// Signed distance to a rounded box (centre, half size, corner radius).
    float teaBox(float2 p, float2 c, float2 h, float r) {
        float2 q = abs(p - c) - h + float2(r);
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    }
    /// About the signed distance to an ellipse (in units of its smaller radius).
    float teaEllipse(float2 p, float2 c, float2 r) {
        float2 q = (p - c) / r;
        return (length(q) - 1.0) * min(r.x, r.y);
    }
    /// Coverage from a signed distance (negative inside), anti-aliased over a pixel.
    float teaCover(float sd, float px) { return saturate(0.5 - sd / max(px, 1e-6)); }

    // ---------------------------------------------------------------- vertices
    vertex TeaOut tea_full_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        TeaOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }
    /// A quad over an NDC rectangle (x0, y0, x1, y1).
    vertex TeaOut tea_rect_vertex(uint vid [[vertex_id]], constant float4& rect [[buffer(2)]]) {
        float2 q = mix(rect.xy, rect.zw, teaQuad[vid]);
        TeaOut o;
        o.pos = float4(q, 0, 1);
        o.ndc = q;
        return o;
    }

    // ---------------------------------------------------------------- the screens
    /// The opening between the panels (screen units: left, right edges).
    float2 teaOpening(constant TeaU& t) {
        float m = 0.5 * (t.span.x + t.span.y), p = 0.5 * (t.span.y - t.span.x);
        return float2(m - t.span.w * p, m + t.span.w * p);
    }
    /// A panel's paper (screen units x0, y0, x1, y1): 0 the left panel, 1 the right.
    float4 teaPanelPaper(constant TeaU& t, int side) {
        float p = 0.5 * (t.span.y - t.span.x), s = t.span.w, st = t.span.z;
        float x0 = side == 0 ? t.span.x - s * p : t.span.y - p + s * p;
        return float4(x0 + st, t.room.x + st, x0 + p - st, t.room.y - st);
    }
    /// How much light passes the kumiko at a window point (1 on paper … 0 on a bar), softened over `soft` (window units).
    float teaKumiko(float2 w, float soft, constant TeaU& t) {
        float pass = 1.0;
        int n = int(t.e.y + 0.5);
        for (int i = 0; i < 12; i++) {
            if (i >= n) break;
            float4 bar = t.bars[i];
            float v = bar.z < 0.5 ? w.x : w.y;
            float mid = 0.5 * (bar.x + bar.y), hw = 0.5 * (bar.y - bar.x);
            pass = min(pass, smoothstep(hw - soft, hw + soft, abs(v - mid)));
        }
        return pass;
    }
    /// Where a point of the screens' plane (screen units) lets light through: (the opening, the paper between the
    /// kumiko), each 0…1, softened over `soft` (screen units). The stiles and the wall around block it.
    float2 teaScreenMask(float2 q, float soft, constant TeaU& t) {
        float sf = max(soft, 1e-4);
        float sill = t.room.x, lintel = t.room.y;
        float vert = smoothstep(sill - sf, sill + sf, q.y) * (1.0 - smoothstep(lintel - sf, lintel + sf, q.y));
        float2 o = teaOpening(t);
        float inOpen = o.y - o.x > 1e-4 ? smoothstep(o.x - sf, o.x + sf, q.x) * (1.0 - smoothstep(o.y - sf, o.y + sf, q.x)) : 0.0;
        float inSpan = smoothstep(t.span.x - sf, t.span.x + sf, q.x) * (1.0 - smoothstep(t.span.y - sf, t.span.y + sf, q.x));
        int side = q.x < 0.5 * (t.span.x + t.span.y) ? 0 : 1;
        float4 r = teaPanelPaper(t, side);
        float2 w = (q - r.xy) / max(r.zw - r.xy, float2(1e-4));
        float inside = min(min(q.x - r.x, r.z - q.x), min(q.y - r.y, r.w - q.y));
        float onPaper = smoothstep(-sf, sf, inside);
        float kum = teaKumiko(w, max(sf / max(r.z - r.x, 1e-3), 0.002), t);
        return float2(inOpen * vert, onPaper * kum * (1.0 - inOpen) * inSpan * vert);
    }

    // ---------------------------------------------------------------- the garden's light
    struct TeaSky {
        float3 amb;      // the sky's light
        float3 sun;      // the sun's direct light (× how much of it there is)
        float3 moon;
        float3 Ls, Lm;   // the sun and the moon in camera space (x right, y up, z ahead)
        float3 fog;      // the fog's colour
        float fogK;      // fog per metre
    };
    TeaSky teaSkyLight(constant SkyU& u, constant TeaU& t) {
        TeaSky k;
        float sunAlt = u.sun.w;
        float moonAlt = toDeg(asin(clamp(u.moon.z, -1.0, 1.0)));
        float cloud = u.horizon.w;
        float sunUp = smoothstep(-3.0, 6.0, sunAlt) * (1.0 - 0.75 * cloud);
        float moonUp = smoothstep(-2.0, 6.0, moonAlt) * u.moonInfo.x * (1.0 - 0.7 * cloud);
        k.sun = mix(float3(1.0, 0.5, 0.28), float3(1.0, 0.95, 0.88), smoothstep(0.0, 25.0, sunAlt)) * (1.6 * sunUp * (1.0 - 0.7 * t.c.x));
        k.moon = float3(0.55, 0.63, 0.82) * (0.32 * moonUp);
        k.amb = u.zenith.rgb * 0.55 + u.horizon.rgb * 0.45;
        k.Ls = float3(dot(u.sun.xyz, u.right.xyz), dot(u.sun.xyz, u.up.xyz), dot(u.sun.xyz, u.forward.xyz));
        k.Lm = float3(dot(u.moon.xyz, u.right.xyz), dot(u.moon.xyz, u.up.xyz), dot(u.moon.xyz, u.forward.xyz));
        float mist = t.c.x;
        k.fogK = 0.006 + 0.045 * mist * mist + 0.6 * smoothstep(0.88, 1.0, mist) + 0.035 * t.c.z;
        k.fog = u.horizon.rgb * 1.02 + t.candle.rgb * 0.01;
        return k;
    }
    float3 teaFog(float3 col, float D, TeaSky k) { return mix(col, k.fog, 1.0 - exp(-D * k.fogK)); }

    /// Snow lit by the sky and the sun or moon: `up` how much it faces up (0 a side … 1 a top), `side` which way it
    /// turns (−1 left … 1 right).
    float3 teaSnowLit(TeaSky k, float up, float side, float grain) {
        float3 n = normalize(float3(side, up, -0.35));
        float s = saturate(dot(n, k.Ls)), m = saturate(dot(n, k.Lm));
        float3 lit = k.amb * (0.78 + 0.32 * up) + k.sun * (0.55 * s) + k.moon * (1.2 * m);
        float3 col = kSnow * lit * (0.95 + 0.05 * grain);
        return mix(col * float3(0.78, 0.87, 1.08), col, saturate(0.45 + 0.55 * up + 0.4 * s));
    }
    /// Stone (or wood, bark, bamboo) lit the same way.
    float3 teaSolidLit(TeaSky k, float3 albedo, float up, float side) {
        float3 n = normalize(float3(side, up, -0.6));
        float s = saturate(dot(n, k.Ls)), m = saturate(dot(n, k.Lm));
        float bounce = 0.32 * saturate(1.0 - up);   // the snow's light thrown up on the faces that look down or out
        return albedo * (k.amb * (0.42 + 0.3 * up + bounce) + k.sun * (0.6 * s + 0.12 * bounce * saturate(k.Ls.y)) + k.moon * (1.3 * m));
    }

    // ---------------------------------------------------------------- the garden's things (metres at their depth)
    /// The snow-viewing lantern (q in metres from the foot of its middle, y up from the snow): three curved legs, the
    /// platform, the six-sided fire box with its window (the candle at night) and a sun and a moon cut in its sides,
    /// the wide roof with upturned tips, the jewel, and its cushion of snow. Returns its cover; writes its colour and
    /// how much of it is the candle-lit window (for the flake's light).
    float teaLantern(float2 q, float px, TeaSky k, constant TeaU& t, thread float3& col) {
        if (abs(q.x) > 0.68 || q.y < -0.06 || q.y > 1.3) return 0.0;
        float ax = abs(q.x);
        // Stone: legs, platform, fire box, roof, the jewel's neck and bulb.
        float yl = saturate(q.y / 0.43);
        float legC = 0.19 + 0.13 * (1.0 - yl) * (1.0 - yl), legT = 0.036 + 0.024 * (1.0 - yl);
        float sdLeg = max(abs(ax - legC) - legT, max(-q.y - 0.02, q.y - 0.44));
        float sdBack = max(abs(q.x) - 0.034, max(-q.y - 0.02, q.y - 0.44));
        float sdPlat = teaBox(q, float2(0.0, 0.465), float2(0.27, 0.04), 0.012);
        float sdBox = teaBox(q, float2(0.0, 0.655), float2(0.165, 0.15), 0.006);
        float tip = max(ax - 0.46, 0.0);
        float roofHigh = 1.0 - 0.21 * saturate(ax / 0.58) + 1.6 * tip * tip;
        float roofLow = ax < 0.17 ? 0.80 : mix(0.80, 0.778, (ax - 0.17) / 0.41) + 1.6 * tip * tip;
        float sdRoof = max(max(q.y - roofHigh, roofLow - q.y), ax - 0.58);
        float sdJewel = min(teaBox(q, float2(0.0, 1.02), float2(0.034, 0.03), 0.01), teaEllipse(q, float2(0.0, 1.09), float2(0.068, 0.058)));
        float sdStone = min(min(min(sdLeg, sdPlat), min(sdBox, sdRoof)), sdJewel);
        float stoneC = teaCover(sdStone, px);
        float backC = teaCover(sdBack, px) * (1.0 - stoneC);
        // Snow: the cushion on the roof (drooping over the eaves), a tuft on the jewel, a ledge on the platform.
        float lumps = teaN1(q.x * 21.0 + 3.1) - 0.5;
        float capLow = ax < 0.58 ? roofHigh - 0.008 : (1.0 - 0.21 + 1.6 * 0.0144) - 0.045 * smoothstep(0.58, 0.63, ax);
        float sdCap = max(teaEllipse(q, float2(0.0, 0.86), float2(0.63, 0.27)) + 0.012 * lumps, capLow - q.y);
        float sdTuft = teaEllipse(q, float2(0.0, 1.16), float2(0.075, 0.045));
        float sdLedge = teaBox(q, float2(0.0, 0.513), float2(0.262, 0.011 + 0.006 * lumps), 0.008);
        float snowC = teaCover(min(min(sdCap, sdTuft), sdLedge), px);
        float cover = max(max(stoneC, backC), snowC);
        if (cover < 0.002) return 0.0;
        // The stone: weathered granite with lichen, its faces turned by where they lie on the fire box and roof.
        float grain = teaF2(q * 16.0);
        float lichen = smoothstep(0.55, 0.8, teaN2(q * 6.0 + 2.0));
        float3 albedo = mix(float3(0.40, 0.40, 0.37), float3(0.33, 0.37, 0.28), 0.6 * lichen) * (0.82 + 0.3 * grain);
        float side = ax < 0.085 ? 0.0 : sign(q.x) * 0.85;
        float up = q.y > 0.78 ? -0.6 : 0.0;   // the roof's underside looks down
        float3 stone = teaSolidLit(k, albedo, up, side);
        // The window and the side cut-outs: dark inside by day; at night the candle burns in the fire box.
        float2 wq = q - float2(0.0, 0.665);
        float inWin = teaCover(teaBox(q, float2(0.0, 0.665), float2(0.055, 0.075), 0.004), px);
        float inSun = teaCover(length(q - float2(-0.124, 0.672)) - 0.028, px);
        float inMoon = teaCover(max(length(q - float2(0.124, 0.672)) - 0.03, 0.024 - length(q - float2(0.137, 0.681))), px);
        float hole = max(inWin, max(inSun, inMoon)) * teaCover(sdBox, px);
        float flame = exp(-dot(wq + float2(0.0, 0.03), wq + float2(0.0, 0.03)) * 120.0);
        float3 glow = t.candle.rgb * (0.35 + 1.4 * flame) * (0.85 + 0.15 * t.candle.w);
        stone = mix(stone, float3(0.012, 0.011, 0.01) + glow, hole);
        // The candle's warmth on the stone round the window and the snow under the roof.
        float near = exp(-dot(wq, wq) * 9.0);
        stone += albedo * t.candle.rgb * (0.12 * near);
        float3 back = teaSolidLit(k, albedo * 0.55, 0.0, 0.0);
        float3 snowCol = teaSnowLit(k, q.y > 0.95 || abs(q.y - 0.513) < 0.02 ? 1.0 : 0.35, sign(q.x) * saturate((ax - 0.35) / 0.3), grain);
        snowCol += kSnow * t.candle.rgb * (0.06 * exp(-dot(wq, wq) * 4.0));
        float3 c = back * backC;
        c = mix(c, stone, stoneC);
        c = mix(c, snowCol, snowC);
        col = c / max(cover, 1e-4);
        return cover;
    }

    /// The stone basin (q in metres from its foot): a squat rounded stone, its hollow of water under a cushion of snow
    /// with a dark eye of water left in the middle, the bamboo ladle resting across it, a snowy front stone and a side
    /// stone. Returns its cover; writes its colour.
    float teaBasin(float2 q, float px, TeaSky k, constant SkyU& u, thread float3& col) {
        if (abs(q.x) > 0.74 || q.y < -0.06 || q.y > 0.72) return 0.0;
        float lumps = teaN1(q.x * 25.0 + 7.0) - 0.5;
        float rough = (teaN2(q * float2(7.0, 5.0) + 1.3) - 0.5) * 0.03;
        float sdStone = teaBox(q, float2(0.0, 0.25), float2(0.31, 0.25), 0.15) + rough;
        float sdSide = teaEllipse(q, float2(-0.55, 0.05), float2(0.18, 0.13)) + rough;
        float sdFront = teaEllipse(q, float2(0.14, -0.02), float2(0.38, 0.1));
        float sdCap = max(teaEllipse(q, float2(0.0, 0.47), float2(0.3, 0.11)) + 0.01 * lumps, 0.44 - q.y);
        float sdEye = teaEllipse(q, float2(0.03, 0.555), float2(0.11, 0.012));
        float2 hs = teaSeg(q, float2(-0.34, 0.6), float2(0.33, 0.572));
        float sdHandle = hs.x - 0.0075;
        float sdCup = teaBox(q, float2(-0.2, 0.6), float2(0.036, 0.03), 0.006);
        float stoneC = teaCover(min(sdStone, sdSide), px);
        float frontC = teaCover(sdFront, px);
        float capC = teaCover(sdCap, px);
        float eyeC = teaCover(sdEye, px) * capC;
        float ladleC = teaCover(min(sdHandle, sdCup), px);
        float cover = max(max(stoneC, frontC), max(capC, ladleC));
        if (cover < 0.002) return 0.0;
        float grain = teaF2(q * 14.0);
        float moss = smoothstep(0.62, 0.85, teaN2(q * 5.0 + 3.0)) * (1.0 - smoothstep(0.1, 0.3, q.y));
        float3 albedo = mix(float3(0.46, 0.46, 0.43), float3(0.30, 0.34, 0.25), 0.6 * moss) * (0.8 + 0.3 * grain);
        float rnd = saturate(abs(q.x) / 0.31);
        float3 stone = teaSolidLit(k, albedo, 0.15 * (1.0 - rnd), sign(q.x) * rnd);
        float capS = smoothstep(-0.02, 0.03, q.y - 0.05 - 0.03 * lumps);
        if (sdSide < sdStone) stone = mix(stone, teaSnowLit(k, 0.9, -0.3, grain), capS);
        float3 front = mix(teaSolidLit(k, albedo * 0.8, 0.0, 0.0), teaSnowLit(k, 0.95, 0.0, grain), smoothstep(-0.08, -0.03, q.y + 0.01 * lumps));
        float3 cap = teaSnowLit(k, saturate((q.y - 0.44) / 0.12), sign(q.x) * saturate(abs(q.x) / 0.3) * 0.6, grain);
        float3 water = u.horizon.rgb * 0.3 + u.zenith.rgb * 0.15 + float3(0.008);
        float node = 1.0 - smoothstep(0.0, 0.004, abs(hs.y - 0.55) - 0.006);
        float3 bamboo = teaSolidLit(k, float3(0.6, 0.53, 0.32) * (1.0 - 0.35 * node), 0.6, 0.0);
        float3 c = stone * stoneC;
        c = mix(c, front, frontC);
        c = mix(c, cap, capC);
        c = mix(c, water, eyeC);
        c = mix(c, bamboo, ladleC);
        col = c / max(cover, 1e-4);
        return cover;
    }

    /// The plum's limbs: trunk, three branches and the straight young shoots (from, to in metres from the trunk's foot).
    constant float4 kPlumSeg[18] = {
        float4(0.00, 0.00, -0.08, 0.45), float4(-0.08, 0.45, 0.06, 0.85), float4(0.06, 0.85, -0.10, 1.20),
        float4(-0.10, 1.20, -0.45, 1.38), float4(-0.45, 1.38, -0.78, 1.34), float4(-0.78, 1.34, -1.10, 1.50),
        float4(-0.10, 1.20, -0.18, 1.62), float4(-0.18, 1.62, -0.40, 1.98), float4(0.06, 0.85, 0.42, 1.08),
        float4(0.42, 1.08, 0.62, 1.42), float4(0.62, 1.42, 0.88, 1.55), float4(-0.45, 1.38, -0.42, 1.80),
        float4(-0.78, 1.34, -0.82, 1.70), float4(-0.18, 1.62, 0.02, 2.05), float4(0.42, 1.08, 0.38, 1.48),
        float4(0.62, 1.42, 0.58, 1.86), float4(0.88, 1.55, 1.02, 1.85), float4(-1.10, 1.50, -1.18, 1.78),
    };
    /// Their half widths (metres) at each end.
    constant float2 kPlumW[18] = {
        float2(0.075, 0.068), float2(0.068, 0.06), float2(0.06, 0.05), float2(0.034, 0.027), float2(0.027, 0.02),
        float2(0.02, 0.012), float2(0.03, 0.022), float2(0.022, 0.012), float2(0.034, 0.027), float2(0.027, 0.019),
        float2(0.019, 0.011), float2(0.008, 0.004), float2(0.007, 0.0035), float2(0.008, 0.0035), float2(0.008, 0.004),
        float2(0.007, 0.0035), float2(0.007, 0.0035), float2(0.007, 0.0035),
    };

    /// The plum tree (q in metres from its trunk's foot): dark gnarled limbs with snow along their tops and straight
    /// shoots, and a few red blossoms by `blossom` (and buds). Returns its cover; writes its colour.
    float teaPlum(float2 q, float px, float blossom, TeaSky k, thread float3& col) {
        if (q.x < -1.32 || q.x > 1.15 || q.y < -0.05 || q.y > 2.15) return 0.0;
        float sd = 1e3, snow = 0.0;
        for (int i = 0; i < 18; i++) {
            float4 s = kPlumSeg[i];
            float2 h = teaSeg(q, s.xy, s.zw);
            float w = mix(kPlumW[i].x, kPlumW[i].y, h.y) * (1.0 + 0.18 * (teaN1(h.y * 9.0 + float(i) * 3.7) - 0.5));
            float d = h.x - w;
            if (d < sd) {
                sd = d;
                // Snow lies along the top of the flatter limbs.
                float2 dir = normalize(s.zw - s.xy);
                float2 pt = mix(s.xy, s.zw, h.y);
                float above = (q.y - pt.y) * abs(dir.x) - (q.x - pt.x) * dir.y * sign(dir.x);
                snow = (abs(dir.y) < 0.75 && i > 2) ? smoothstep(0.2 * w, 0.75 * w, above) : 0.0;
            }
        }
        float limb = teaCover(sd, px);
        // Blossoms: two places on each branch and shoot; a share of them open (the rest buds), by the setting.
        float bloom = 0.0, bud = 0.0;
        float3 petal = float3(0);
        if (blossom > 0.01) {
            for (int i = 3; i < 18; i++) {
                float4 s = kPlumSeg[i];
                for (int j = 0; j < 2; j++) {
                    float h = teaH2(float2(float(i), float(j) * 7.0 + 1.0));
                    if (h > blossom) continue;
                    float tt = 0.3 + 0.5 * float(j) + 0.15 * (teaH2(float2(float(i) * 3.0, float(j) + 9.0)) - 0.5);
                    float2 c = mix(s.xy, s.zw, tt) + (float2(teaH2(float2(float(i), float(j) + 3.0)), teaH2(float2(float(j), float(i) + 5.0))) - 0.5) * 0.05;
                    float2 d = q - c;
                    float r = length(d);
                    if (r > 0.05) continue;
                    bool open = h < blossom * 0.7;
                    float ang = atan2(d.y, d.x) + h * 6.0;
                    float petals = 0.032 * (0.72 + 0.28 * abs(cos(2.5 * ang)));
                    float rr = open ? petals : 0.014;
                    float cv = teaCover(r - rr, px);
                    if (cv > bloom + bud) {
                        if (open) { bloom = cv; bud = 0.0; } else { bud = cv; bloom = 0.0; }
                        float centre = open ? 1.0 - smoothstep(0.006, 0.011, r) : 0.0;
                        petal = mix(open ? float3(0.80, 0.13, 0.22) : float3(0.55, 0.06, 0.12), float3(0.98, 0.86, 0.5), centre);
                    }
                }
            }
        }
        float flower = max(bloom, bud);
        float cover = max(limb, flower);
        if (cover < 0.002) return 0.0;
        float grain = teaN2(q * 30.0);
        float lichen = smoothstep(0.6, 0.85, teaN2(q * 7.0 + 4.0));
        float3 bark = teaSolidLit(k, mix(float3(0.11, 0.085, 0.075), float3(0.22, 0.25, 0.19), 0.5 * lichen) * (0.85 + 0.3 * grain), 0.2, 0.0);
        float3 c = mix(bark, teaSnowLit(k, 1.0, 0.0, grain), snow);
        float3 flowers = teaSolidLit(k, petal, 0.4, 0.0) * 1.25;
        c = mix(c * limb, flowers, flower);
        col = c / max(cover, 1e-4);
        return cover;
    }

    /// The pine's foliage pads (centre x, y, half width, half height in metres from its trunk's foot), widest to the
    /// right where it reaches over the garden.
    constant float4 kPinePad[6] = {
        float4(-0.78, 0.86, 0.62, 0.15), float4(0.58, 1.20, 0.72, 0.17), float4(-0.55, 1.64, 0.62, 0.16),
        float4(1.28, 1.90, 0.80, 0.18), float4(0.30, 2.44, 0.64, 0.20), float4(-0.38, 2.16, 0.42, 0.13),
    };
    /// Where each pad's limb leaves the trunk (fraction up the trunk's curve).
    constant float kPineFrom[6] = { 0.32, 0.45, 0.62, 0.72, 0.95, 0.85 };

    /// A point on the pine's trunk (a curve from its foot leaning over to the right), its half width there.
    float2 teaPineTrunk(float s) {
        float2 a = float2(0.0, 0.0), b = float2(-0.38, 1.15), c = float2(0.55, 2.35);
        float m = 1.0 - s;
        return a * (m * m) + b * (2.0 * m * s) + c * (s * s);
    }

    /// The pine (q in metres from its trunk's foot, D its distance): the leaning trunk, its limbs and six cloud-pruned
    /// pads of needles, each pressed down under a cushion of snow; rime feathers their windward edges. Returns its cover;
    /// writes its colour.
    float teaPine(float2 q, float px, float D, TeaSky k, constant SkyU& u, thread float3& col) {
        if (q.x < -1.5 || q.x > 2.2 || q.y < -0.05 || q.y > 2.78) return 0.0;
        float tanV = u.up.w;
        float toScreen = 1.0 / (D * tanV);
        // The trunk and limbs.
        float sdWood = 1e3;
        float2 prev = teaPineTrunk(0.0);
        for (int j = 1; j <= 6; j++) {
            float2 pt = teaPineTrunk(float(j) / 6.0);
            float2 h = teaSeg(q, prev, pt);
            float w = mix(0.09, 0.04, (float(j - 1) + h.y) / 6.0) * (1.0 + 0.15 * (teaN1(q.y * 6.0) - 0.5));
            sdWood = min(sdWood, h.x - w);
            prev = pt;
        }
        for (int i = 0; i < 6; i++) {
            float2 from = teaPineTrunk(kPineFrom[i]);
            float2 h = teaSeg(q, from, kPinePad[i].xy);
            sdWood = min(sdWood, h.x - mix(0.03, 0.014, h.y));
        }
        // The pads: needles in tufts, the ends drooping under the snow, the snow's cushion on top.
        float sdPad = 1e3, sdSnow = 1e3;
        float2 outward = float2(0.0, 1.0);
        for (int i = 0; i < 6; i++) {
            float4 pd = kPinePad[i];
            float rel = (q.x - pd.x) / pd.z;
            float2 qq = q + float2(0.0, 0.07 * rel * rel);
            float below = saturate((pd.y - qq.y) / pd.w);
            float tuft = (teaN2(q * 9.0 + float2(float(i) * 5.0, 1.0)) - 0.5) * (0.05 + 0.08 * below);
            float d = teaEllipse(qq, pd.xy - float2(0.0, 0.02), pd.zw * float2(1.0, 1.15)) + tuft;
            if (d < sdPad) { sdPad = d; outward = (qq - pd.xy) / pd.zw; }
            float lumpy = (teaN1(q.x * 5.0 + float(i) * 2.0) - 0.5);
            float cushion = teaEllipse(qq, pd.xy + float2(0.0, 0.07), pd.zw * float2(0.97, 0.78)) + 0.02 * lumpy;
            float lowEdge = pd.y + pd.w * (0.05 + 0.4 * lumpy);
            sdSnow = min(sdSnow, max(cushion, lowEdge - qq.y));
        }
        float woodC = teaCover(sdWood, px), padC = teaCover(sdPad, px), snowC = teaCover(sdSnow, px);
        float cover = max(max(woodC, padC), snowC);
        if (cover < 0.002) return 0.0;
        float grain = teaN2(q * 24.0);
        float3 bark = teaSolidLit(k, float3(0.16, 0.11, 0.08) * (0.8 + 0.4 * grain), 0.1, 0.3);
        float needle = teaN2(q * float2(60.0, 22.0));
        float3 needles = teaSolidLit(k, float3(0.05, 0.095, 0.06) * (0.7 + 0.6 * needle), 0.3, 0.0);
        float3 snowCol = teaSnowLit(k, 1.0, 0.0, grain);
        float3 c = bark * woodC;
        c = mix(c, needles, padC);
        c = mix(c, snowCol, snowC);
        // Rime on the pads' and the limbs' windward edges.
        float inside = -min(min(sdPad, sdSnow), sdWood) * toScreen;
        if (rimeNear(u, inside)) {
            float r = rimeEdge(u, inside, normalize(outward + float2(0.0, 0.001)), q * toScreen);
            c = mix(c, rimeColor(u) * cover, r * cover);
        }
        col = c / max(cover, 1e-4);
        return cover;
    }

    /// A low bamboo fence (q in metres along it, y up from the snow): posts, thin canes and three rails tied with dark
    /// cord, snow along the rails and on the posts; rime feathers the canes. Returns its cover; writes its colour.
    float teaFence(float2 q, float px, float D, TeaSky k, constant SkyU& u, thread float3& col) {
        if (q.y < -0.05 || q.y > 1.13) return 0.0;
        float toScreen = 1.0 / (D * u.up.w);
        float postX = q.x - 1.8 * floor(q.x / 1.8 + 0.5);
        float caneX = q.x - 0.3 * floor(q.x / 0.3 + 0.5);
        float sdPost = max(abs(postX) - 0.04, q.y - 1.05);
        float sdCane = max(abs(caneX) - 0.013, q.y - 0.97);
        float rails[3] = { 0.3, 0.62, 0.94 };
        float sdRail = 1e3, rail = 0.3;
        for (int i = 0; i < 3; i++) {
            float d = abs(q.y - rails[i]) - 0.016;
            if (d < sdRail) { sdRail = d; rail = rails[i]; }
        }
        float lump = teaN1(q.x * 7.0 + rail * 11.0);
        float sdRailSnow = max(abs(q.y - rail - 0.026) - 0.011 - 0.006 * lump, 0.3 - lump);
        float sdPostSnow = teaEllipse(float2(postX, q.y), float2(0.0, 1.07), float2(0.055, 0.026));
        float woodSd = min(min(sdPost, sdCane), sdRail);
        float woodC = teaCover(woodSd, px);
        float snowC = teaCover(min(sdRailSnow, sdPostSnow), px);
        float tie = teaCover(max(abs(caneX) - 0.018, abs(q.y - rail) - 0.02), px) * step(sdRail, 0.0);
        float cover = max(woodC, snowC);
        if (cover < 0.002) return 0.0;
        float node = 1.0 - smoothstep(0.0, 0.008, abs(fract(q.y / 0.27 + caneX * 3.0) - 0.5) - 0.48);
        float3 bamboo = teaSolidLit(k, float3(0.50, 0.46, 0.30) * (1.0 - 0.3 * node), sdRail < sdCane ? 0.6 : 0.0, sdRail < sdCane ? 0.0 : sign(caneX));
        bamboo = mix(bamboo, float3(0.02, 0.018, 0.016), tie);
        float3 c = mix(bamboo * woodC, teaSnowLit(k, 1.0, 0.0, lump), snowC);
        float inside = -woodSd * toScreen;
        if (rimeNear(u, inside)) {
            float2 outward = sdRail < min(sdPost, sdCane) ? float2(0.0, q.y > rail ? 1.0 : -1.0) : float2(sdPost < sdCane ? sign(postX) : sign(caneX), 0.0);
            c = mix(c, rimeColor(u) * cover, rimeEdge(u, inside, outward, q * toScreen) * woodC);
        }
        col = c / max(cover, 1e-4);
        return cover;
    }

    /// Snowy cedars beyond the fence (q in metres along the ground at their distance): shaggy narrow cones in a ragged
    /// row, clumps of snow lodged in them. Returns the cover; writes the colour (before the fog).
    float teaCedars(float2 q, float px, TeaSky k, thread float3& col) {
        float cell = floor(q.x / 1.5);
        float cover = 0.0;
        for (int j = -1; j <= 1; j++) {
            float c = cell + float(j);
            float h = teaH1(c * 1.37 + 0.5);
            if (h < 0.06) continue;
            float cx = (c + 0.5 + 0.6 * (teaH1(c * 2.1) - 0.5)) * 1.5;
            float ht = 4.0 + 3.8 * teaH1(c * 3.3 + 1.0);
            float y = q.y / ht;
            if (y < -0.02 || y > 1.04) continue;
            float shag = teaN2(float2(q.x * 2.4, q.y * 1.9) + float2(c * 7.0, 0.0));
            float taper = (1.0 - y) * sqrt(saturate((1.04 - y) / 0.2));    // a cone, rounded at its tip
            float w = (0.95 + 0.5 * h) * taper * (0.78 + 0.44 * shag) + 0.05;
            float cv = teaCover(abs(q.x - cx) - w, px);
            if (cv > cover) {
                cover = cv;
                float clumps = teaN2(float2(q.x * 3.2, q.y * 2.6) + float2(c * 3.0, 4.0));
                float tier = fract(y * 7.0 + h * 3.0);
                float lodged = smoothstep(0.55, 0.85, tier) * smoothstep(0.3, 0.6, clumps) + 0.2 * smoothstep(0.75, 0.9, clumps);
                float3 green = teaSolidLit(k, float3(0.035, 0.06, 0.048) * (0.8 + 0.4 * shag), 0.2, 0.0);
                col = mix(green, teaSnowLit(k, 0.9, 0.0, h), saturate(0.06 + 0.8 * lodged));
            }
        }
        return cover;
    }

    /// The veranda's boards outside the screens (X across, Z out from the eye, metres): polished dark wood mirroring the
    /// snow's light, a dusting of snow blown in along its edge.
    float3 teaEngawa(float X, float Z, float zEdge, float pxm, TeaSky k, constant TeaU& t) {
        float zin = Z - kZWall;
        float board = fract(zin / 0.16);
        float seam = 1.0 - smoothstep(0.0, max(0.02, pxm / 0.16), min(board, 1.0 - board));
        float grain = teaN2(float2(X * 1.6, zin * 40.0)) * 0.6 + teaN2(float2(X * 5.0, zin * 90.0 + 3.0)) * 0.4;
        float3 wood = mix(float3(0.24, 0.15, 0.09), float3(0.34, 0.22, 0.13), grain) * (1.0 - 0.5 * seam);
        float3 lit = wood * (k.amb * 0.55 + t.inside.rgb * 0.5 + k.sun * 0.25 * saturate(k.Ls.y));
        float3 sheen = (k.amb * 0.9 + k.sun * 0.15) * (0.22 + 0.18 * (zin / 0.95));   // the bright garden in the polish
        float3 col = lit + sheen * (1.0 - 0.6 * seam);
        float drift = zEdge - (0.05 + 0.12 * teaN1(X * 2.3 + 1.0)) * (0.4 + 0.6 * t.c.z);
        float snow = smoothstep(drift - 0.02, drift + 0.02, Z);
        return mix(col, teaSnowLit(k, 1.0, 0.0, grain), snow);
    }

    /// The snow on the ground (X across, D out, metres): soft drifts in blue hollows, glinting where the sun or the
    /// moon catches a facet, a warm pool round the lantern at night and its shadow by day.
    float3 teaGroundSnow(float X, float D, float2 pix, TeaSky k, constant TeaU& t, float lanternX, float lanternD) {
        float n = teaF2(float2(X * 0.55, D * 0.3));
        float lit = saturate(0.5 + (n - 0.5) * 1.5);
        float3 col = teaSnowLit(k, 0.55 + 0.45 * lit, (n - 0.5) * 0.6, n);
        // The lantern's shadow (by day) and its candle's warmth on the snow (at night).
        float2 dl = float2(X - lanternX - k.Ls.x * 0.4, (D - lanternD) * 0.35);
        float shade = exp(-dot(dl, dl) * 6.0) * saturate(length(k.sun) * 0.5);
        col *= 1.0 - 0.35 * shade;
        float2 dc = float2(X - lanternX, (D - lanternD) * 0.4);
        col += kSnow * t.candle.rgb * (0.05 * exp(-dot(dc, dc) * 1.2));
        // Glints: a facet per two pixels, catching the sun or the moon when it's tilted just right.
        float2 cell = floor(pix * 0.5);
        float3 h = hash33(float3(cell, 3.0));
        float3 nf = normalize(float3((h.x - 0.5) * 0.8, 1.0, (h.y - 0.5) * 0.8));
        float3 V = float3(0.0, 0.25, -1.0);
        float tw = 0.6 + 0.4 * sin(t.a.w * (1.5 + 3.0 * h.z) + h.z * 40.0);
        float gs = smoothstep(0.994, 1.0, dot(nf, normalize(k.Ls + V))) * saturate(length(k.sun));
        float gm = smoothstep(0.995, 1.0, dot(nf, normalize(k.Lm + V))) * saturate(length(k.moon) * 3.0);
        col += (float3(1.0, 0.95, 0.85) * gs * 4.0 + float3(0.75, 0.82, 1.0) * gm * 2.0) * tw * t.b.w * smoothstep(9.0, 12.0, D);
        return col;
    }

    // ---------------------------------------------------------------- the garden through the opening
    fragment ColorDepth tea_garden_fragment(TeaOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant TeaU& t [[buffer(1)]]) {
        ColorDepth out;
        float aspect = t.a.y, horizon = t.a.z;
        float2 s = float2(in.ndc.x * aspect, in.ndc.y);
        float tanV = u.up.w;
        float pa = u.weather.w;                                   // a pixel's angle: px metres at D is pa × D
        TeaSky k = teaSkyLight(u, t);
        float mid = 0.5 * (t.span.x + t.span.y);                  // the opening's centre (screen units)
        // The veranda, right outside the sill.
        float eyeRoom = (horizon - t.room.x) * kZWall * tanV;     // the eye above the room's floor (m)
        float zEdge = kZWall + 0.95;
        float edgeY = horizon - eyeRoom / (zEdge * tanV);
        if (s.y < edgeY) {
            float Z = eyeRoom / max((horizon - s.y) * tanV, 1e-4);
            float3 col = teaEngawa(s.x * Z * tanV, Z, zEdge, pa * Z, k, t);
            out.color = float4(col, 1.0); out.depth = float4(0.12, 0, 0, 1);
            return out;
        }
        float3 acc = float3(0);
        float a = 0.0, depth = 1.0;
        float3 col;
        // The flake a hard note knocks off the lantern's cap: a clump of snow tumbling down with a little powder.
        float lanternD = 9.5, lanternX = mid * lanternD * tanV - 0.55;
        if (t.flake.w > 0.5) {
            float age = t.flake.y, side = t.flake.x * 2.0 - 1.0;
            float fall = min(age, 1.6);
            float2 start = float2(lanternX + side * 0.58, 0.83);
            float2 at = start + float2(side * (0.1 + 0.12 * t.flake.z) * fall + 0.05 * t.c.y * fall, -(0.25 * fall + 0.28 * fall * fall));
            at.y = max(at.y, 0.0);
            float2 q = float2(s.x * lanternD * tanV, kEyeGarden + (s.y - horizon) * lanternD * tanV) - at;
            float px = pa * lanternD;
            float landed = smoothstep(1.4, 1.7, age);
            float fade = 1.0 - smoothstep(2.4, 4.0, age);
            float clump = 0.0, rim = 0.0;
            for (int i = 0; i < 4; i++) {
                float2 off = (float2(teaH1(float(i) * 3.1 + 0.3), teaH1(float(i) * 5.7 + 1.1)) - 0.5) * (0.06 + 0.3 * landed) + float2(0.0, 0.016 * float(i) * fall);
                float r = (0.045 - 0.008 * float(i)) * (1.0 - 0.5 * landed);
                float d = length(q - off) - r;
                clump = max(clump, teaCover(d, px));
                rim = max(rim, teaCover(d - 1.5 * px, px) * (1.0 - teaCover(d + 0.5 * px, px)));
            }
            float2 pq = q * float2(4.0, 2.5);
            float powder = exp(-dot(pq, pq) * 22.0) * 0.45 * (1.0 - landed);
            float cv = saturate(max(clump, rim) + powder) * fade;
            if (cv > 0.002) {
                float3 lit = teaSnowLit(k, 0.9, 0.0, 0.5) * 1.25 + kSnow * t.candle.rgb * 0.1;
                col = mix(lit, lit * float3(0.6, 0.7, 0.88), rim * (1.0 - clump));   // its shadowed edge against the snow
                float c = cv * (1.0 - a); acc += c * col; a += c;
            }
        }
        // The basin, the lantern, the plum, the pine, then the fence: each in its own depth plane.
        {
            float D = 8.4;
            float2 q = float2(s.x * D * tanV - (mid * D * tanV + 0.95), kEyeGarden + (s.y - horizon) * D * tanV);
            float cv = teaBasin(q, pa * D, k, u, col);
            if (cv > 0.002) { col = teaFog(col, D, k); float c = cv * (1.0 - a); acc += c * col; a += c; if (cv > 0.5 && depth > 0.9) depth = 0.25; }
        }
        if (a < 0.995) {
            float D = lanternD;
            float2 q = float2(s.x * D * tanV - lanternX, kEyeGarden + (s.y - horizon) * D * tanV);
            float cv = teaLantern(q, pa * D, k, t, col);
            if (cv > 0.002) { col = teaFog(col, D, k); float c = cv * (1.0 - a); acc += c * col; a += c; if (cv > 0.5 && depth > 0.9) depth = 0.27; }
        }
        if (a < 0.995) {
            float D = 10.2;
            float2 q = float2(s.x * D * tanV - (mid * D * tanV + 2.25), kEyeGarden + (s.y - horizon) * D * tanV);
            float cv = teaPlum(q, pa * D, t.d.x, k, col);
            if (cv > 0.002) { col = teaFog(col, D, k); float c = cv * (1.0 - a); acc += c * col; a += c; if (cv > 0.5 && depth > 0.9) depth = 0.3; }
        }
        if (a < 0.995) {
            float D = 12.0;
            float2 q = float2(s.x * D * tanV - (mid * D * tanV - 2.45), kEyeGarden + (s.y - horizon) * D * tanV);
            float cv = teaPine(q, pa * D, D, k, u, col);
            if (cv > 0.002) { col = teaFog(col, D, k); float c = cv * (1.0 - a); acc += c * col; a += c; if (cv > 0.5 && depth > 0.9) depth = 0.34; }
        }
        if (a < 0.995) {
            float D = 15.0;
            float2 q = float2(s.x * D * tanV + 0.4, kEyeGarden + (s.y - horizon) * D * tanV);
            float cv = teaFence(q, pa * D, D, k, u, col);
            if (cv > 0.002) { col = teaFog(col, D, k); float c = cv * (1.0 - a); acc += c * col; a += c; if (cv > 0.5 && depth > 0.9) depth = 0.42; }
        }
        // The snow on the ground out to the cedars, then the cedars, then the sky (left to the dome; heavy fog veils it).
        if (a < 0.995) {
            float D = s.y < horizon ? kEyeGarden / max((horizon - s.y) * tanV, 1e-5) : 1e4;
            if (D < 30.0) {
                col = teaGroundSnow(s.x * D * tanV, D, in.pos.xy, k, t, lanternX, lanternD);
                col = teaFog(col, D, k);
                float c = 1.0 - a; acc += c * col; a = 1.0;
                if (depth > 0.9) depth = saturate(D / 40.0);
            } else {
                float Dc = 40.0;
                float2 q = float2(s.x * Dc * tanV, kEyeGarden + (s.y - horizon) * Dc * tanV + 0.6);
                float cv = q.y > 0.0 ? teaCedars(q, pa * Dc, k, col) : 0.0;
                if (s.y < horizon) {
                    // The snow beyond: under the cedars' feet, out to the haze.
                    float3 g = teaFog(teaGroundSnow(s.x * D * tanV, D, in.pos.xy, k, t, lanternX, lanternD), min(D, 300.0), k);
                    col = cv > 0.002 ? mix(g, teaFog(col, Dc, k), cv) : g;
                    float c = 1.0 - a; acc += c * col; a = 1.0;
                } else if (cv > 0.002) {
                    col = teaFog(col, Dc, k);
                    float c = cv * (1.0 - a); acc += c * col; a += c;
                }
                if (depth > 0.9 && cv > 0.5) depth = 0.85;
            }
        }
        // Heavy fog whitens the sky low down too.
        float veil = (1.0 - exp(-45.0 * k.fogK)) * (1.0 - smoothstep(horizon, horizon + 0.6, s.y)) * 0.9;
        if (a < 0.999 && veil > 0.002) { float c = veil * (1.0 - a); acc += c * k.fog; a += c; }
        // The candle's glow in the air round the lantern (night).
        float2 lq = float2(s.x * lanternD * tanV - lanternX, kEyeGarden + (s.y - horizon) * lanternD * tanV - 0.64);
        float3 air = t.candle.rgb * (0.035 * exp(-dot(lq, lq) * 5.0) * (1.0 + 2.0 * t.c.x));
        if (a < 0.002 && dot(air, float3(1.0)) < 0.003) {
            discard_fragment();
            out.color = float4(0, 0, 0, 0); out.depth = float4(1, 0, 0, 1);
            return out;
        }
        out.color = float4(acc + air, a);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the paper
    /// The paper on the panels (the opening is left to the garden): washi glowing with the sky's light through it,
    /// cloudy with long fibres, pink on a pastel dawn, blue-grey at night with the brazier's warmth on it; falling snow
    /// throws faint moving specks on it by day. The Window Kit draws the kumiko and stiles over it, and its ice.
    fragment ColorDepth tea_paper_fragment(TeaOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant TeaU& t [[buffer(1)]]) {
        ColorDepth out;
        float aspect = t.a.y;
        float2 s = float2(in.ndc.x * aspect, in.ndc.y);
        float2 o = teaOpening(t);
        if (o.y - o.x > 1e-4 && s.x > o.x && s.x < o.y) {
            discard_fragment();
            out.color = float4(0, 0, 0, 1); out.depth = float4(1, 0, 0, 1);
            return out;
        }
        int side = s.x < 0.5 * (t.span.x + t.span.y) ? 0 : 1;
        float4 r = teaPanelPaper(t, side);
        float2 w = (s - r.xy) / max(r.zw - r.xy, float2(1e-4));
        // Slide with the panel: the paper's texture is fixed to it.
        float2 pp = float2(s.x - r.x, s.y) + float2(float(side) * 17.0, 0.0);
        float cloud = teaF2(pp * float2(6.0, 5.0));
        float fibre = teaN2(float2(pp.x * 140.0 + pp.y * 23.0, pp.y * 18.0 - pp.x * 9.0));
        float fibre2 = teaN2(float2(pp.x * 31.0 - pp.y * 7.0, pp.y * 150.0 + pp.x * 11.0));
        float texture = 0.955 + 0.06 * cloud + 0.03 * smoothstep(0.62, 0.9, fibre) + 0.025 * smoothstep(0.65, 0.92, fibre2);
        float3 glow = t.paper.rgb * texture * (0.95 + 0.08 * w.y * t.b.y);
        // The brazier's warmth on the inside of the paper near it, and on the right panel's foot.
        float2 fb = (s - float2(t.e.z, t.e.w + 0.05)) * float2(0.8, 1.2);
        glow += t.fire.rgb * (0.025 * exp(-dot(fb, fb) * 3.0));
        // Falling snow's soft specks drifting down the paper by day.
        float snow = t.c.z * t.b.y;
        if (snow > 0.05) {
            float2 cs = float2(s.x * 26.0, s.y * 26.0 + t.a.w * 1.6);
            float2 cell = floor(cs);
            float2 f = fract(cs) - 0.5;
            float2 jit = float2(teaH2(cell), teaH2(cell + 7.3)) - 0.5;
            float sp = exp(-dot(f - 0.6 * jit, f - 0.6 * jit) * 70.0) * step(0.55, teaH2(cell + 3.1));
            glow *= 1.0 - 0.07 * sp * snow;
        }
        out.color = float4(glow, 1.0);
        out.depth = float4(0.08, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the room
    /// The light the brazier's coals throw about the room: warm, softer than their own glow.
    float3 teaFireIllum(constant TeaU& t) { return float3(1.0, 0.74, 0.54) * t.fire.r; }
    /// That light at a room surface point (screen units p), falling off from the brazier.
    float3 teaFireLight(float2 p, constant TeaU& t) {
        float2 d = (p - float2(t.e.z, t.e.w + 0.02)) * float2(0.85, 1.25);
        return teaFireIllum(t) * (0.09 / (1.0 + 8.0 * dot(d, d)));
    }

    /// The tatami from the sill to the table (p in screen units below the eye): mats along the screens' wall, then mats
    /// laid the other way, their dark borders and woven rush; lit by the room, by the screens (more near them, with the
    /// kumiko's soft shadows), by the sun through the opening and the paper, and by the brazier.
    float3 teaTatami(float2 p, float px, constant TeaU& t, constant SkyU& u) {
        float horizon = t.a.z, sill = t.room.x, tanV = u.up.w;
        float eyeRoom = (horizon - sill) * kZWall * tanV;
        float Z = eyeRoom / max((horizon - p.y) * tanV, 1e-4);   // from the eye (m)
        float X = p.x * Z * tanV;                                // across (m)
        float zin = max(kZWall - Z, 0.0);                        // in from the screens' wall (m)
        float pxm = px * Z * tanV;                               // a pixel across, on the floor
        float pzm = pxm * Z / max(eyeRoom, 0.1);                 // and along it
        float heri = 0.0, edge = 0.0;
        float weave;
        float matId;
        if (zin < 0.955) {
            // The row along the wall: long sides along it, borders on them.
            float d = min(zin, 0.955 - zin);
            heri = 1.0 - smoothstep(0.03 - pzm, 0.03 + pzm, d);
            float mx = (X + 2.865) / 1.91;
            float e = abs(fract(mx + 0.5) - 0.5) * 1.91;
            edge = 1.0 - smoothstep(0.0, 0.004 + pxm, e);
            weave = 0.5 + 0.5 * sin(zin * 349.0) * (1.0 - smoothstep(0.004, 0.012, pzm));
            matId = floor(mx);
        } else {
            // The mats beyond lie the other way: borders along their long sides, which run toward the screens.
            float mx = (X + 2.865) / 0.955;
            float d = abs(fract(mx + 0.5) - 0.5) * 0.955;
            heri = 1.0 - smoothstep(0.03 - pxm, 0.03 + pxm, d);
            float e = abs(zin - 2.865);
            edge = 1.0 - smoothstep(0.0, 0.004 + pzm, e);
            weave = 0.5 + 0.5 * sin(X * 349.0) * (1.0 - smoothstep(0.004, 0.012, pxm));
            matId = floor(mx) + 10.0;
        }
        float tone = teaH1(matId * 1.7 + 0.3);
        float3 straw = mix(float3(0.60, 0.55, 0.35), float3(0.58, 0.57, 0.36), tone) * (0.92 + 0.08 * weave);
        straw *= 0.94 + 0.06 * teaN2(float2(X * 3.0, zin * 3.0));
        float3 albedo = mix(straw * (1.0 - 0.35 * edge), float3(0.035, 0.035, 0.045), heri);
        // Light from the screens: what this point sees of them along the light's way in (the kumiko's shadows), and the
        // sun's own patch through the opening (and, fainter, the paper).
        float3 L = t.sun.xyz;
        float2 hit = float2(X + zin * L.x / max(L.z, 0.05), zin * L.y / max(L.z, 0.05));
        float wallScale = 1.0 / (kZWall * tanV);
        float2 q = float2(hit.x * wallScale, sill + hit.y * wallScale);
        float soft = (0.004 + zin * mix(0.16, 0.012, t.sun.w)) * wallScale;
        float2 mk = teaScreenMask(q, soft, t);
        float lumOpen = dot(t.open.rgb, float3(0.333)), lumPaper = dot(t.paper.rgb, float3(0.333));
        float avgLum = max(t.span.w * lumOpen + (1.0 - t.span.w) * 0.85 * lumPaper, 1e-4);
        float pattern = (mk.x * lumOpen + mk.y * lumPaper) / avgLum;
        float3 screens = t.paper.rgb * (1.0 - t.span.w) + t.open.rgb * t.span.w;
        float near = 0.5 * (1.0 - zin / sqrt(zin * zin + 1.6 * 1.6));
        float3 light = t.inside.rgb * 0.5 + screens * (near * 0.85) * mix(1.0, pattern, 0.6);
        light += t.sunCol.rgb * (t.sun.w * saturate(L.y) * (mk.x + 0.28 * mk.y) * 0.9);
        light += teaFireLight(p, t) * 1.3;
        float3 col = albedo * light;
        // The borders' cloth has a faint sheen of the screens.
        col += screens * (0.04 * heri * near);
        return col;
    }

    /// The hanging scroll (q in the scroll's units: x −1…1 across its paper and border, y 0 at the roller … 1 at the
    /// top rod): the mounting's silk, its gold strips, the hanging strips, the roller's knobs, and on the paper an ensō
    /// (one circle of the brush, left open) and a small red seal. Returns its cover; writes its colour (unlit albedo).
    float teaScroll(float2 q, float px, float tall, thread float3& col) {
        if (q.y < -0.02 || q.y > 1.02 || abs(q.x) > 1.16) return 0.0;
        float knob = (q.y < 0.022 && abs(q.x) < 1.12) ? 1.0 : 0.0;
        float body = abs(q.x) < 1.0 ? 1.0 : 0.0;
        if (knob + body < 0.5) return 0.0;
        float3 silk = float3(0.25, 0.25, 0.23) * (0.9 + 0.12 * teaN2(q * float2(90.0, 300.0)));
        float3 c = silk;
        if (q.y > 0.985) c = float3(0.10, 0.07, 0.05);                                   // the top rod
        else if (q.y < 0.022) c = abs(q.x) > 1.0 ? float3(0.20, 0.13, 0.08) : float3(0.12, 0.08, 0.05);   // the roller and its knobs
        else if ((q.y > 0.785 && q.y < 0.8) || (q.y > 0.205 && q.y < 0.22)) c = float3(0.42, 0.33, 0.17);   // the gold strips
        else if (q.y > 0.22 && q.y < 0.785 && abs(q.x) < 0.8) {
            // The paper: cream, a little foxed; the ensō on it.
            float2 pp = float2(q.x / 0.8, (q.y - 0.22) / 0.565);           // −1…1 across, 0…1 up the paper
            float2 e = float2(pp.x, (pp.y - 0.53) * 0.565 * tall);        // round on the paper (tall: its height over half its width)
            float r = length(e);
            float ang = atan2(e.y, e.x);
            float phi = fmod(4.1 - ang + 12.566370, 6.283185);          // clockwise from the brush's landing
            float3 paperCol = float3(0.80, 0.75, 0.62) * (0.94 + 0.08 * teaN2(pp * 9.0));
            float ink = 0.0;
            if (phi < 5.75) {
                float u2 = phi / 5.75;
                float R = 0.62 * (1.0 + 0.035 * sin(3.0 * phi + 0.5));
                float wdt = 0.13 * (1.0 - 0.65 * u2) + 0.02;
                float dr = abs(r - R);
                float stroke = 1.0 - smoothstep(wdt * 0.85, wdt, dr);
                float dry = smoothstep(0.35, 0.65, teaN1(phi * 38.0 + (r - R) * 140.0));
                ink = stroke * mix(1.0, dry, smoothstep(0.55, 0.95, u2)) * (0.86 + 0.14 * teaN1(phi * 7.0));
            }
            float seal = (abs(pp.x + 0.62) < 0.07 && abs(pp.y - 0.12) < 0.05) ? 0.85 * step(0.2, teaN2(pp * 60.0)) : 0.0;
            c = mix(paperCol, float3(0.60, 0.14, 0.11), seal);
            c = mix(c, kInk, ink);
        } else if (q.y > 0.22 && q.y < 0.785) {
            c = float3(0.34, 0.32, 0.28) * (0.9 + 0.12 * teaN2(q * float2(60.0, 200.0)));   // the side borders
        }
        // The hanging strips down the upper silk.
        if (q.y > 0.8 && q.y < 0.985 && abs(abs(q.x) - 0.3) < 0.06) c = float3(0.36, 0.35, 0.31);
        col = c;
        return 1.0;
    }

    /// The camellia in its slim bamboo vase on the alcove's floor (q in screen units from the vase's foot, s its scale):
    /// returns the cover; writes its colour (unlit albedo).
    float teaCamellia(float2 q, float sc, float px, thread float3& col) {
        float2 v = q / sc;
        float sdVase = teaBox(v, float2(0.0, 0.1), float2(0.022, 0.1), 0.004);
        float sdStem = teaSeg(v, float2(0.0, 0.19), float2(0.03, 0.27)).x - 0.003;
        float sdLeaf = min(teaEllipse(v, float2(0.045, 0.255), float2(0.03, 0.012)), teaEllipse(v, float2(-0.02, 0.24), float2(0.026, 0.011)));
        float sdBud = teaEllipse(v, float2(0.032, 0.29), float2(0.016, 0.022));
        float pxv = px / sc;
        float vc = teaCover(sdVase, pxv), sc2 = teaCover(sdStem, pxv), lc = teaCover(sdLeaf, pxv), bc = teaCover(sdBud, pxv);
        float cover = max(max(vc, sc2), max(lc, bc));
        if (cover < 0.002) return 0.0;
        float node = 1.0 - smoothstep(0.0, 0.004, abs(v.y - 0.13) - 0.002);
        float3 c = float3(0.36, 0.30, 0.17) * (0.8 + 0.3 * sqrt(saturate(1.0 - abs(v.x) / 0.022))) * (1.0 - 0.4 * node) * vc;
        c = mix(c, float3(0.08, 0.12, 0.05), sc2);
        c = mix(c, float3(0.04, 0.10, 0.05), lc);
        c = mix(c, float3(0.62, 0.05, 0.10), bc);
        col = c / max(cover, 1e-4);
        return cover;
    }

    /// The alcove (p in screen units, left of its post): a recess behind the screens' plane, seen in the room's one-point
    /// perspective: its back wall with the scroll and the camellia below it, its floor behind the lacquered front edge,
    /// its ceiling and side wall. Dim, lit from the screens at its right.
    float3 teaAlcove(float2 p, float px, constant TeaU& t, constant SkyU& u) {
        float aspect = t.a.y, horizon = t.a.z, sill = t.room.x, lintel = t.room.y, right = t.room.w;
        float left = -aspect - 0.25;
        float kb = kZWall / (kZWall + kAlcoveDepth);           // the back wall's scale about the vanishing point (0, horizon)
        float2 vp = float2(0.0, horizon);
        float floorFront = sill + 0.06;
        float floorBack = horizon + (floorFront - horizon) * kb;
        float topBack = horizon + (lintel - horizon) * kb;
        float backLeft = left * kb;
        float3 room = t.inside.rgb;
        float toward = smoothstep(left, right, p.x);            // nearer the screens, more of their light
        float3 light = room * (0.3 + 0.5 * toward) + t.paper.rgb * (0.06 + 0.1 * toward) + teaFireLight(p, t) * 0.4;
        float3 col;
        if (p.y < floorFront) {
            // The lacquered front edge of the alcove's floor.
            float f = (p.y - sill) / 0.06;
            float3 lacquer = float3(0.025, 0.02, 0.018);
            col = lacquer * light * 2.0 + t.paper.rgb * (0.08 * smoothstep(0.7, 1.0, f));
        } else if (p.y < floorBack) {
            // Its floor: a pale board (receding to the back wall).
            float Z = (horizon - floorFront) / max(horizon - p.y, 1e-4) * kZWall;
            float g = teaN2(float2(p.x / max(Z, 0.1) * 12.0, Z * 9.0));
            col = float3(0.42, 0.32, 0.22) * (0.85 + 0.25 * g) * light * 1.1;
        } else if (p.y > topBack) {
            col = float3(0.30, 0.25, 0.20) * light * 0.6;      // its ceiling, in shadow
        } else if (p.x < backLeft) {
            col = float3(0.46, 0.39, 0.30) * light * 0.75;     // the side wall
        } else {
            // The back wall: earthen plaster, the scroll on it, the camellia below.
            float g = teaF2(p * 40.0);
            float fleck = smoothstep(0.82, 0.9, teaN2(p * 230.0));
            col = float3(0.47, 0.40, 0.31) * (0.9 + 0.15 * g + 0.08 * fleck) * light;
            float centre = 0.5 * (left + right) * kb;
            float sw = min(0.14 * kb, 0.32 * (right - backLeft));
            float sTop = topBack - 0.05, sBot = floorBack + 0.17;
            float2 sq = float2((p.x - centre) / sw, (p.y - sBot) / max(sTop - sBot, 1e-3));
            float3 sc;
            float scv = teaScroll(sq, px / sw, 0.565 * (sTop - sBot) / max(0.8 * sw, 1e-3), sc);
            if (scv > 0.0) col = mix(col, sc * light * 1.15, scv);
            // The scroll's cord up to its hook.
            if (abs(p.x - centre) < 0.0025 && p.y > sTop && p.y < topBack) col = float3(0.08, 0.06, 0.05) * light;
            float3 fc;
            float fcv = teaCamellia(p - float2(centre + sw * 1.45, floorBack), kb, px, fc);
            if (fcv > 0.0) col = mix(col, fc * light * 1.2, fcv);
        }
        return col;
    }

    /// A post or beam of planed wood (across −1…1 over its width).
    float3 teaWood(float2 p, float across, float3 light, float3 back, float rimSide) {
        float g = teaN2(float2(across * 3.0, p.y * 30.0)) * 0.6 + teaN2(float2(across * 9.0 + 3.0, p.y * 80.0)) * 0.4;
        float3 albedo = mix(float3(0.36, 0.25, 0.16), float3(0.50, 0.37, 0.25), g);
        float rnd = sqrt(saturate(1.0 - across * across));
        return albedo * light * (0.65 + 0.35 * rnd) + back * (0.12 * smoothstep(0.6, 1.0, across * rimSide));
    }

    /// The tea bowl on the table: a black raku bowl, its rim an ellipse round the tea's green froth, lit from behind by
    /// the screens along its edges. Returns its cover; writes its colour.
    float teaBowl(float2 p, float px, constant TeaU& t, float3 screens, thread float3& col) {
        float bx = t.bowl.x, rimY = t.bowl.y, hw = t.bowl.z;
        float H = 0.13, foot = rimY - H;
        float2 q = float2(p.x - bx, p.y - foot);
        if (abs(q.x) > hw + 0.02 || q.y < -0.01 || q.y > H + 0.05) return 0.0;
        float er = 0.038;
        float v = saturate((q.y - 0.018) / 0.07);
        float wall = hw * (0.47 + 0.53 * sqrt(v)) * (1.0 - 0.025 * saturate((q.y - 0.09) / 0.04));
        float sdBody = max(abs(q.x) - wall, max(0.018 - q.y, q.y - H));
        float sdFoot = max(abs(q.x) - 0.42 * hw, max(-q.y, q.y - 0.02));
        float sdMouth = teaEllipse(q, float2(0.0, H), float2(hw * 0.975, er));
        float sd = min(min(sdBody, sdFoot), sdMouth);
        float cover = teaCover(sd, px);
        if (cover < 0.002) return 0.0;
        float3 room = t.inside.rgb + teaFireLight(p, t);
        float glaze = teaN2(q * float2(40.0, 28.0));
        float3 black = float3(0.035, 0.031, 0.029) * (0.8 + 0.4 * glaze);
        float edge = smoothstep(wall - 0.018, wall, abs(q.x));
        float3 c = black * room * 1.6 + screens * (0.32 * edge * smoothstep(0.02, 0.06, q.y)) + room * (0.05 * glaze * glaze);
        if (sdMouth < 0.0) {
            // Inside the mouth: the bowl's inner wall behind, the tea's surface in front, a bright lip round the rim.
            float sdTea = teaEllipse(q, float2(0.0, H - 0.011), float2(hw * 0.86, er * 0.72));
            float3 innerWall = black * room * 1.2 + screens * 0.05;
            float froth = teaN2(q * 260.0);
            float3 tea = float3(0.30, 0.46, 0.12) * (0.85 + 0.25 * froth) * (room * 1.4 + screens * 0.35);
            c = mix(innerWall, tea, teaCover(sdTea, px));
            float lip = 1.0 - smoothstep(0.0, 0.006, -sdMouth);
            c = mix(c, black * room + screens * 0.22, lip);
        }
        col = c;
        return cover;
    }

    /// The brazier on the tatami (a round amber-glazed hibachi of ash and glowing charcoal) with the iron kettle on its
    /// trivet: the kettle's bumpy body, its lid and knob, the spout and the arching handle. Returns its cover; writes
    /// its colour.
    float teaBrazier(float2 p, float px, constant TeaU& t, float3 screens, thread float3& col) {
        float bx = t.e.z, rimY = t.e.w;
        float2 q = p - float2(bx, rimY);
        if (abs(q.x) > 0.26 || q.y < -0.2 || q.y > 0.3) return 0.0;
        float3 fire = t.fire.rgb;
        float3 room = t.inside.rgb;
        // The hibachi: a barrel with a foot, its rim round the ash.
        float yb = (q.y + 0.085) / 0.085;
        float bw = 0.17 * (1.0 - 0.1 * yb * yb);
        float sdBody = max(abs(q.x) - bw, max(-0.17 - q.y, q.y));
        float sdFootRing = max(abs(q.x) - 0.15, max(-0.182 - q.y, q.y + 0.165));
        float sdRim = teaEllipse(q, float2(0.0, 0.0), float2(0.158, 0.036));
        float sdHib = min(min(sdBody, sdFootRing), sdRim);
        // The kettle on its trivet.
        float2 kq = q - float2(0.0, 0.10);
        float sdKettle = teaEllipse(kq, float2(0.0), float2(0.125, 0.075));
        float sdLid = min(teaEllipse(q, float2(0.0, 0.168), float2(0.056, 0.017)), teaEllipse(q, float2(0.0, 0.19), float2(0.014, 0.012)));
        float2 sp = teaSeg(q, float2(-0.105, 0.112), float2(-0.178, 0.168));
        float sdSpout = sp.x - mix(0.016, 0.008, sp.y);
        float2 hq = (q - float2(0.0, 0.14)) / float2(0.095, 0.13);
        float sdHandle = q.y > 0.135 ? abs(length(hq) - 1.0) * 0.095 - 0.0055 : 1e3;
        float sdLugs = min(length(q - float2(-0.095, 0.142)), length(q - float2(0.095, 0.142))) - 0.01;
        float sdLegs = 1e3;
        for (int i = 0; i < 3; i++) {
            float lx = (float(i) - 1.0) * 0.07;
            sdLegs = min(sdLegs, max(abs(q.x - lx) - 0.006, max(-0.012 - q.y, q.y - 0.035)));
        }
        float sdIron = min(min(min(sdKettle, sdLid), min(sdSpout, sdHandle)), min(sdLugs, sdLegs));
        float hibC = teaCover(sdHib, px), ironC = teaCover(sdIron, px);
        float cover = max(hibC, ironC);
        if (cover < 0.002) return 0.0;
        // The hibachi's glaze: amber brown, glossy, the screens' light along its edges; inside the rim, the ash and the coals.
        float g = teaN2(q * float2(30.0, 60.0));
        float3 glaze = float3(0.30, 0.16, 0.075) * (0.85 + 0.25 * g);
        float sideEdge = smoothstep(bw - 0.03, bw, abs(q.x));
        float3 hib = glaze * (room * 1.3) + screens * (0.28 * sideEdge) + glaze * fire * (0.12 * saturate(q.y / 0.17 + 1.0));
        hib += screens * (0.1 * exp(-(q.x + 0.06) * (q.x + 0.06) * 400.0) * saturate(-q.y / 0.17));   // a soft highlight down its side
        if (sdRim < 0.0) {
            float ash = teaN2(q * 140.0);
            float3 inside = float3(0.33, 0.31, 0.29) * (0.8 + 0.3 * ash) * room;
            float coal = smoothstep(0.45, 0.6, teaN2(q * float2(26.0, 48.0) + 3.0)) * (1.0 - smoothstep(0.08, 0.14, abs(q.x)));
            float crack = smoothstep(0.55, 0.65, teaN2(q * float2(90.0, 130.0))) * coal;
            inside = mix(inside, float3(0.02, 0.018, 0.016), coal);
            inside += fire * (0.5 * crack + 0.18 * coal * (0.5 + 0.5 * t.fire.w)) * (0.4 + 0.6 * t.b.x);
            float lipK = 1.0 - smoothstep(0.0, 0.005, -sdRim);
            hib = mix(inside, glaze * room * 1.6 + screens * 0.18, lipK);
        }
        // The iron: dark, bumpy (arare), the screens' light on its top and edges, the coals' glow beneath.
        float2 bu = kq / float2(0.125, 0.075);
        float2 cell = bu / float2(0.11, 0.12);
        float2 f = fract(cell) - 0.5;
        float bump = exp(-dot(f, f) * 9.0) * step(length(bu), 1.0);
        float facingUp = saturate(bu.y * 0.8 + 0.4);
        float3 iron = float3(0.06, 0.056, 0.052) * room * 1.4;
        iron += screens * (0.16 * facingUp * (0.5 + bump) + 0.12 * smoothstep(0.75, 1.0, length(bu)));
        iron += fire * (0.22 * saturate(-bu.y) * step(length(bu), 1.05));
        if (sdSpout < 0.0 || sdHandle < 0.0 || sdLugs < 0.0) iron = float3(0.05, 0.047, 0.044) * room * 1.4 + screens * 0.1;
        if (sdLegs < 0.0 && sdKettle > 0.0) iron = float3(0.03) * room + fire * 0.25;
        float3 c = hib * hibC;
        c = mix(c, iron, ironC);
        col = c / max(cover, 1e-4);
        return cover;
    }

    fragment ColorDepth tea_room_fragment(TeaOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant TeaU& t [[buffer(1)]]) {
        ColorDepth o;
        float aspect = t.a.y, keyTop = t.a.x, horizon = t.a.z;
        float2 p = float2(in.ndc.x * aspect, in.ndc.y);
        if (p.y < keyTop) {
            o.color = float4(0, 0, 0, 1); o.depth = float4(0.05, 0, 0, 1);
            return o;
        }
        float sill = t.room.x, lintel = t.room.y, tableFar = t.room.z, alcoveR = t.room.w;
        float L = t.span.x, R = t.span.y;
        float tanV = u.up.w;
        float px = u.weather.w / max(tanV, 1e-4);   // a pixel in screen units
        float3 room = t.inside.rgb;
        float3 screens = t.paper.rgb * (1.0 - t.span.w) + t.open.rgb * t.span.w;
        // The bowl and the brazier with its kettle stand in front of everything here.
        float3 objCol = float3(0);
        float obj = teaBrazier(p, px, t, screens, objCol);
        float3 bowlCol;
        float bowl = teaBowl(p, px, t, screens, bowlCol);
        if (bowl > obj) { obj = bowl; objCol = bowlCol; }
        bool inSpan = p.x > L && p.x < R && p.y > sill && p.y < lintel;
        if (inSpan) {
            if (obj < 0.002) {
                discard_fragment();
                o.color = float4(0, 0, 0, 0); o.depth = float4(1, 0, 0, 1);
                return o;
            }
            o.color = float4(objCol * obj, obj); o.depth = float4(0.06, 0, 0, 1);
            return o;
        }
        float3 col;
        float depth = 0.07;
        float3 fireLit = teaFireLight(p, t);
        if (p.y >= lintel) {
            // Above the screens: the lintel beam, the earthen wall over it and the ceiling's edge; over the alcove its
            // own lower wall and rail; the posts run on up.
            float3 light = room * 0.8 + screens * 0.12 + fireLit * 0.5;
            float g = teaF2(p * 38.0);
            float fleck = smoothstep(0.83, 0.9, teaN2(p * 260.0));
            float3 plaster = float3(0.55, 0.47, 0.36) * (0.9 + 0.14 * g + 0.07 * fleck) * light;
            float ceiling = lintel + 0.86 * (1.0 - lintel);
            if (p.x >= alcoveR && p.x < L) {
                col = teaWood(p, (p.x - alcoveR) / (L - alcoveR) * 2.0 - 1.0, light, screens, 1.0);
            } else if (p.x >= R) {
                col = teaWood(p, (p.x - R) / 0.07 * 2.0 - 1.0, light, screens, -1.0);
            } else if (p.x < alcoveR) {
                col = p.y < lintel + 0.022 ? float3(0.05, 0.035, 0.025) * light * 2.0 : plaster * 0.92;
            } else if (p.y < lintel + 0.045) {
                float across = (p.y - lintel) / 0.045 * 2.0 - 1.0;
                col = teaWood(p.yx, across, light * (1.05 - 0.25 * across), screens, -1.0) + screens * (0.08 * saturate(-across));
            } else {
                col = plaster;
            }
            if (p.y > ceiling) {
                float bt = fract(p.x / max(p.y - horizon, 0.1) * 2.2);
                col = float3(0.40, 0.30, 0.21) * light * (0.85 + 0.15 * smoothstep(0.0, 0.05, min(bt, 1.0 - bt)));
                if (p.y < ceiling + 0.014) col = float3(0.30, 0.21, 0.14) * light;
            }
        } else if (p.x < alcoveR && p.y >= sill) {
            col = teaAlcove(p, px, t, u);
            depth = 0.09;
        } else if (p.x >= alcoveR && p.x < L && p.y >= sill) {
            // The alcove's post: a natural log, lit from the screens at its right.
            float across = (p.x - alcoveR) / (L - alcoveR) * 2.0 - 1.0;
            float3 light = room * 0.9 + screens * 0.1 + fireLit * 0.5;
            col = teaWood(p, across, light, screens, 1.0) * (0.9 + 0.1 * teaN1(p.y * 7.0));
        } else if (p.x >= R && p.y >= sill) {
            float across = (p.x - R) / 0.07 * 2.0 - 1.0;
            col = teaWood(p, across, room * 0.9 + fireLit * 0.5, screens, -1.0);
        } else if (p.y >= sill - 0.014 && p.x >= L && p.x < R) {
            // The sill: planed wood worn smooth, its two grooves, the screens' light shining in it.
            float f = (p.y - (sill - 0.014)) / 0.014;
            float groove = (abs(f - 0.33) < 0.08 || abs(f - 0.7) < 0.08) ? 0.55 : 1.0;
            float g = teaN2(float2(p.x * 30.0, f * 3.0));
            col = mix(float3(0.42, 0.31, 0.21), float3(0.52, 0.40, 0.28), g) * (room + fireLit) * groove + screens * 0.18 * groove;
        } else if (p.y >= tableFar) {
            col = teaTatami(p, px, t, u);
            depth = 0.08;
        } else {
            // The low table: dark polished wood, mirroring the screens at its far side; the bowl's dark image in it.
            float f = saturate((p.y - keyTop) / max(tableFar - keyTop, 1e-3));
            float g = teaN2(float2(p.x * 2.2, p.y * 90.0)) * 0.6 + teaN2(float2(p.x * 7.0, p.y * 200.0)) * 0.4;
            float3 wood = mix(float3(0.07, 0.04, 0.025), float3(0.13, 0.075, 0.045), g);
            float2 mk = teaScreenMask(float2(p.x, sill + (lintel - sill) * (0.8 - 0.3 * f)), 0.05, t);
            float3 mirrored = t.open.rgb * mk.x + t.paper.rgb * mk.y + room * (0.25 * (1.0 - mk.x - mk.y));
            float fres = 0.05 + 0.25 * f * f;
            float3 mb;
            float foot = t.bowl.y - 0.13;
            float img = teaBowl(float2(p.x, 2.0 * foot - p.y), px, t, screens, mb);
            mirrored *= 1.0 - 0.85 * img;
            col = wood * (room * 1.1 + fireLit) + mirrored * fres;
            // The bowl's soft shadow on the table, and the table's far edge catching the light.
            float2 sd = (p - float2(t.bowl.x, foot + 0.005)) / float2(t.bowl.z * 1.1, 0.03);
            col *= 1.0 - 0.45 * exp(-dot(sd, sd));
            if (p.y > tableFar - 0.006) col += screens * 0.1;
            depth = 0.05;
        }
        col = mix(col, objCol, obj);
        o.color = float4(col, 1.0);
        o.depth = float4(obj > 0.5 ? 0.06 : depth, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the tea's steam
    /// The ribbon's lateral offset at height h (0 the bowl … 1 the top), between its 12 points.
    float teaPath(float h, constant TeaU& t) {
        float x = saturate(h) * 11.0;
        int i = min(int(floor(x)), 10);
        float f = x - float(i);
        float a = t.path[i / 4][i % 4], b = t.path[(i + 1) / 4][(i + 1) % 4];
        return mix(a, b, f * f * (3.0 - 2.0 * f));
    }

    /// The steam: two to four soft ribbons rising from the bowl along the run's path, swaying and breaking up as they
    /// climb; the wisps your notes send curling off them (brighter while held); a chord's rounder puff, warm or cool.
    /// Lit from behind by the screens (bright against the paper and the snow), from the room in front of the walls.
    fragment float4 tea_steam_fragment(TeaOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant TeaU& t [[buffer(1)]]) {
        float aspect = t.a.y, time = t.a.w;
        float2 p = float2(in.ndc.x * aspect, in.ndc.y);
        float bx = t.bowl.x, rimY = t.bowl.y, bw = t.bowl.z, H = max(t.bowl.w, 0.05);
        float h = (p.y - rimY) / H;
        if (h < -0.04 || h > 1.25) { discard_fragment(); return float4(0); }
        float glow = t.d.y;
        // The ribbons.
        int n = int(t.e.x + 0.5);
        float alpha = 0.0;
        float wander = 0.0;
        for (int i = 0; i < 4; i++) {
            if (i >= n) break;
            float fi = float(i);
            float base = (fi - 0.5 * float(n - 1)) / max(float(n - 1), 1.0) * 0.55 * bw;
            float hh = saturate(h);
            float x = bx + base * (1.0 + 0.9 * hh) + teaPath(hh, t) * 0.17 * smoothstep(0.0, 0.2, hh);
            x += (0.015 + 0.07 * hh) * sin(hh * 6.0 - time * 0.9 + fi * 2.3) + 0.025 * hh * sin(hh * 15.0 - time * 1.7 + fi * 5.1);
            float w = 0.016 + 0.075 * hh + 0.004 * fi;
            float dx = (p.x - x) / w;
            float fadeIn = smoothstep(0.0, 0.16, h), fadeOut = (1.0 - hh) * (1.0 - hh);
            float breakup = 0.25 + 0.75 * smoothstep(0.25, 0.75, teaF2(float2(hh * 4.0 - time * 0.4, fi * 3.1 + dx * 0.3)));
            alpha += exp(-dx * dx) * fadeIn * fadeOut * breakup * 0.26;
            wander += exp(-dx * dx);
        }
        // The wisps: each rises from its place across the bowl's mouth, curls out to its side and hooks over at its head.
        int nw = int(t.d.w + 0.5);
        float wisps = 0.0;
        for (int i = 0; i < 24; i++) {
            if (i >= nw) break;
            float4 wa = t.wisp[i], wb = t.wispB[i];
            float bright = wa.w;
            if (bright < 0.01) continue;
            float rise = max(wa.y, 0.02), curl = wa.z, age = wb.x, seed = wb.w;
            float top = rimY + rise * H * 1.05 + 0.02 * age;
            float reach = (0.05 + 0.16 * rise) * curl;
            float hook = 0.022 + 0.035 * rise;
            if (p.y < rimY - 0.02 || p.y > top + 2.2 * hook || abs(p.x - wa.x - 0.5 * reach) > abs(reach) * 0.6 + 3.0 * hook + 0.05) continue;
            float sgn = curl < 0.0 ? -1.0 : 1.0;
            float d = 1e3, along = 0.0;
            float2 prev = float2(wa.x, rimY);
            for (int j = 1; j <= 5; j++) {
                float f = float(j) / 5.0;
                float2 pt = float2(wa.x + reach * f * f + 0.024 * f * sin(f * 6.5 + seed * 6.28 + time * 0.8), rimY + (top - rimY) * f);
                float2 s = teaSeg(p, prev, pt);
                if (s.x < d) { d = s.x; along = (float(j - 1) + s.y) / 5.0; }
                prev = pt;
            }
            float2 cc = prev + float2(sgn * hook, 0.0);
            for (int j = 1; j <= 4; j++) {
                float th = 3.14159265 - float(j) * 1.25;
                float2 pt = cc + float2(sgn * hook * cos(th), hook * sin(th));
                float2 s = teaSeg(p, prev, pt);
                if (s.x < d) { d = s.x; along = 1.0 + (float(j - 1) + s.y) / 4.0 * 0.5; }
                prev = pt;
            }
            float w = (0.011 + 0.017 * along) * (1.0 + 0.4 * min(age, 3.0));
            float wisp = exp(-(d * d) / (w * w)) * smoothstep(0.0, 0.2, along) * (1.0 - 0.45 * smoothstep(1.0, 1.5, along));
            wisp *= 0.6 + 0.4 * teaN1(along * 5.0 + seed * 11.0 - time * 0.35);
            wisps = max(wisps, wisp * bright * (0.6 + 0.4 * wb.z));
        }
        // The chord's puff: a rounder cloud rising and spreading, warm for major, cool for minor.
        float puffA = 0.0;
        float3 tint = float3(1.0);
        float ps = t.puff.z;
        if (ps > 0.002) {
            float age = t.puff.w;
            float2 c = float2(t.puff.x, rimY + 0.1 + 0.32 * H * (1.0 - exp(-age / 1.2)));
            float r = 0.06 + 0.11 * (1.0 - exp(-age / 1.5));
            float2 dq = (p - c) / r;
            float n2 = teaF2(dq * 1.8 + float2(age * 0.3, -age * 0.5));
            float dd = length(dq) + 0.45 * (n2 - 0.5);
            puffA = (1.0 - smoothstep(0.55, 1.0, dd)) * ps * 0.55;
            tint = mix(float3(0.80, 0.88, 1.08), float3(1.10, 0.92, 0.74), t.puff.y);
        }
        float a = saturate(alpha + wisps * 0.85 + puffA);
        if (a < 0.002) { discard_fragment(); return float4(0); }
        // Lit from behind where the screens are behind it (the opening's snow light or the paper's), else by the room.
        float2 o = teaOpening(t);
        bool overSpan = p.x > t.span.x && p.x < t.span.y && p.y > t.room.x && p.y < t.room.y;
        bool overOpen = overSpan && p.x > o.x && p.x < o.y;
        float3 back = overOpen ? t.open.rgb : (overSpan ? t.paper.rgb : t.inside.rgb * 0.8);
        // Steam scatters the light behind it forward: against the bright screens it glows a little brighter than they do.
        float3 light = back * 1.18 + t.inside.rgb * 0.45 + teaFireIllum(t) * 0.04 + float3(0.004);
        float3 c = light * (0.95 + 0.65 * glow) * mix(float3(1.0), tint, saturate(puffA / max(a, 1e-3)));
        return float4(c * a, a * 0.6);
    }

    // ---------------------------------------------------------------- keys: hinoki and lacquer, lantern amber where you play
    struct TeaKey { float4 rect; float4 info; };   // rect NDC; info: black, glow, pressed, light
    struct TeaKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex TeaKeyOut tea_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant TeaKey* keys [[buffer(0)]]) {
        TeaKey k = keys[iid];
        TeaKeyOut o;
        o.uv = teaQuad[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth tea_keys_fragment(TeaKeyOut in [[stage_in]], constant TeaU& t [[buffer(1)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float g = teaN2(float2(in.uv.x * 3.0 + in.pos.x * 0.01, in.uv.y * 40.0));
        float3 base = black ? float3(0.018, 0.014, 0.012) : float3(0.62, 0.52, 0.38) * (0.9 + 0.12 * g);
        float y2 = in.uv.y * in.uv.y;
        float sheen = y2 * y2 * y2 * (black ? 0.08 : 0.1) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * (1.0 - smoothstep(0.94, 1.0, in.uv.x));
        float3 amber = float3(1.0, 0.62, 0.28);
        float3 c = base * (t.inside.rgb * 1.4 + teaFireIllum(t) * 0.04 + float3(light * 0.12)) + float3(0.9, 0.85, 0.75) * sheen * (0.3 + light)
                 + amber * glow * (1.7 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
