/// Shared cinematic finishing for every theme: glow (bloom), depth of field,
/// colour grade, warmth, ACES tone mapping, vignette and film grain.
enum PostShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FSOut { float4 pos [[position]]; float2 uv; };
    constexpr sampler lin(filter::linear, address::clamp_to_edge);

    vertex FSOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        FSOut o;
        o.pos = float4(p[vid], 0, 1);
        o.uv = float2((p[vid].x + 1) * 0.5, 1 - (p[vid].y + 1) * 0.5);
        return o;
    }

    fragment float4 bright_pass(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                                constant float& threshold [[buffer(0)]]) {
        float3 c = src.sample(lin, in.uv).rgb;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        float k = max(l - threshold, 0.0) / max(l, 1e-4);
        return float4(c * k, 1);
    }

    fragment float4 downsample(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float3 c = src.sample(lin, in.uv + t * float2(-1, -1)).rgb + src.sample(lin, in.uv + t * float2(1, -1)).rgb
                 + src.sample(lin, in.uv + t * float2(-1, 1)).rgb + src.sample(lin, in.uv + t * float2(1, 1)).rgb;
        return float4(c * 0.25, 1);
    }

    // Drawn with additive blending onto the next-larger level.
    fragment float4 upsample(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        float2 t = 1.0 / float2(src.get_width(), src.get_height());
        float3 c = src.sample(lin, in.uv).rgb * 4.0;
        c += (src.sample(lin, in.uv + float2(t.x, 0)).rgb + src.sample(lin, in.uv - float2(t.x, 0)).rgb
            + src.sample(lin, in.uv + float2(0, t.y)).rgb + src.sample(lin, in.uv - float2(0, t.y)).rgb) * 2.0;
        c += src.sample(lin, in.uv + t).rgb + src.sample(lin, in.uv - t).rgb
           + src.sample(lin, in.uv + float2(t.x, -t.y)).rgb + src.sample(lin, in.uv + float2(-t.x, t.y)).rgb;
        return float4(c / 16.0, 1);
    }

    struct DofU { float strength; float focus; };
    fragment float4 dof_gather(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                               texture2d<float> depth [[texture(1)]], constant DofU& u [[buffer(0)]]) {
        float d = depth.sample(lin, in.uv).r;
        float coc = clamp(abs(d - u.focus) * u.strength * 2.0, 0.0, 1.0);
        float2 t = 1.0 / float2(src.get_width(), src.get_height()) * coc * 6.0;
        float3 acc = src.sample(lin, in.uv).rgb;
        float w = 1.0;
        for (int i = 0; i < 16; i++) {
            float a = float(i) * 2.39996;
            float r = sqrt(float(i + 1) / 16.0);
            acc += src.sample(lin, in.uv + float2(cos(a), sin(a)) * r * t).rgb;
            w += 1.0;
        }
        return float4(acc / w, 1);
    }

    struct CompU { float exposure; float bloom; float grain; float vignette; float warmth; float time; float grade; float dofMix; };

    float3 aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }

    fragment float4 composite(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                              texture2d<float> dof [[texture(1)]], texture2d<float> bloom [[texture(2)]],
                              constant CompU& u [[buffer(0)]]) {
        float3 c = mix(scene.sample(lin, in.uv).rgb, dof.sample(lin, in.uv).rgb, u.dofMix);
        c += bloom.sample(lin, in.uv).rgb * u.bloom;
        c *= u.exposure;
        c *= float3(1.0 + 0.12 * u.warmth, 1.0 + 0.02 * u.warmth, 1.0 - 0.14 * u.warmth);
        int g = int(u.grade + 0.5);
        if (g == 1) { c *= float3(1.07, 1.0, 0.88); }                                  // Warm Film
        else if (g == 2) { c *= float3(0.9, 1.0, 1.1); }                              // Cool Film
        else if (g == 3) { float l = dot(c, float3(0.333)); c = mix(c, float3(l) + 0.06, 0.22) * float3(1.04, 0.98, 1.07); } // Dreamy
        else if (g == 4) { float l = dot(c, float3(0.2126, 0.7152, 0.0722)); c = max(mix(float3(l), c, 1.35), 0.0); }       // Vivid
        c = aces(c);
        float2 q = in.uv - 0.5;
        c *= 1.0 - u.vignette * dot(q, q) * 1.6;
        float n = fract(sin(dot(in.uv * 1000.0 + u.time, float2(12.9898, 78.233))) * 43758.5453);
        c += (n - 0.5) * u.grain * 0.08;
        return float4(c, 1);
    }
    """
}
