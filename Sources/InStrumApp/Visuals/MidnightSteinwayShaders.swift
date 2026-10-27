/// Metal source for the Midnight Steinway look. Compiled at runtime so the
/// package needs no .metal build step.
enum MidnightSteinwayShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // params: x = keyTop (NDC y), y = bloom, z = ambience, w = spotlight count
    struct StageUniforms { float4 params; float4 spots[64]; };
    struct StageOut { float4 pos [[position]]; float2 p; };

    vertex StageOut stage_vertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        StageOut o;
        o.pos = float4(corners[vid], 0, 1);
        o.p = corners[vid];
        return o;
    }

    fragment float4 stage_fragment(StageOut in [[stage_in]], constant StageUniforms& u [[buffer(0)]]) {
        float2 p = in.p;
        float keyTop = u.params.x, bloom = u.params.y, ambience = u.params.z;
        int count = int(u.params.w);
        float3 col = float3(0.043, 0.035, 0.027);                       // #0B0907
        float sheen = smoothstep(1.3, 0.0, length((p - float2(0.0, 0.95)) * float2(0.6, 1.4)));
        col += sheen * float3(0.05, 0.04, 0.03);                          // glossy lacquer
        float3 spot = float3(1.0, 0.851, 0.627);                          // #FFD9A0
        float3 amber = float3(1.0, 0.706, 0.353);                         // #FFB45A
        float h = p.y - keyTop;
        if (h > 0.0) {
            for (int i = 0; i < count; i++) {
                float sx = -0.98 + u.spots[i].x * 1.96;
                float width = 0.02 + h * 0.16;
                float d = (p.x - sx) / width;
                float cone = exp(-d * d) * exp(-h * 1.2);
                col += spot * cone * u.spots[i].y * 0.5;
            }
            col += amber * bloom * 0.28 * exp(-h * 0.8);
            // faint reflection of the light on the lacquered fall-board
            col += amber * bloom * 0.15 * exp(-h * 18.0);
        }
        col += float3(1.0, 0.78, 0.5) * ambience * 0.05 * (1.2 - abs(p.y));
        return float4(col, 1.0);
    }

    // rect: x0, y0 (bottom), x1, y1 (top) in NDC; info: isBlack, glow, pressed
    struct KeyInstance { float4 rect; float4 info; };
    struct KeyOut { float4 pos [[position]]; float2 uv; float4 info; };

    vertex KeyOut key_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant KeyInstance* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        KeyInstance k = keys[iid];
        KeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }

    fragment float4 key_fragment(KeyOut in [[stage_in]]) {
        float isBlack = in.info.x, glow = in.info.y, pressed = in.info.z;
        float2 uv = in.uv;
        float3 ivory = float3(0.949, 0.922, 0.867);                       // #F2EBDD
        float3 ebony = float3(0.078, 0.071, 0.063);                       // #141210
        float3 amber = float3(1.0, 0.706, 0.353);
        float3 col;
        if (isBlack > 0.5) {
            col = ebony + float3(0.10) * smoothstep(0.8, 1.0, uv.y)        // glossy top bevel
                        + float3(0.04) * smoothstep(0.3, 0.0, abs(uv.x - 0.5) - 0.2);
            if (pressed > 0.5) col *= 1.3;
        } else {
            col = ivory * mix(0.84, 1.0, uv.y);                            // soft shading toward the player
            if (pressed > 0.5) col *= 0.9;
        }
        float edge = 1.0 - smoothstep(0.0, 0.16, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
        col = mix(col, amber, glow * (isBlack > 0.5 ? 0.35 : 0.22));
        col += amber * glow * edge * 0.8;
        return float4(col, 1.0);
    }
    """
}
