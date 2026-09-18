// CaptureStream blit shaders (MSL 3.0)
#include <metal_stdlib>
using namespace metal;

// ---------- 缩放核 ----------

// Catmull-Rom bicubic 权重
static inline float4 bicubicWeights(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    float4 w;
    w.x = -0.1666667 * t3 + 0.5 * t2 - 0.5 * t + 0.1666667;
    w.y =  1.3333333 * t3 - 2.5 * t2 + 1.0;
    w.z = -1.3333333 * t3 + 2.0 * t2 + 0.5 * t + 0.1666667;
    w.w =  0.1666667 * t3 - 0.5 * t2;
    return w / (w.x + w.y + w.z + w.w);
}

static inline float lanczos2(float x) {
    const float a = 2.0;
    x = fabs(x);
    if (x < 1e-5) return 1.0;
    if (x >= a) return 0.0;
    float pix = M_PI_F * x;
    return (a * sin(pix) * sin(pix / a)) / (pix * pix);
}

// ---------- 顶点 ----------

struct BlitVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct DestUniforms {
    float4 quadNDC;   // xy = 中心 NDC，zw = 宽高（NDC 单位）
};

vertex BlitVertexOut blitVS(uint vid [[vertex_id]],
                            constant DestUniforms &u [[buffer(0)]]) {
    // 三角形带：0(-1,1) 1(1,1) 2(-1,-1) 3(1,-1)
    float2 corners[4] = { float2(-1.0,  1.0), float2(1.0,  1.0),
                          float2(-1.0, -1.0), float2(1.0, -1.0) };
    float2 c = corners[vid];
    BlitVertexOut out;
    out.position = float4(u.quadNDC.xy + c * u.quadNDC.zw * 0.5, 0.0, 1.0);
    // uv 左上原点（与 destRect 一致）：corner (-1,1) → uv (0,0)
    out.uv = float2((c.x + 1.0) * 0.5, 1.0 - (c.y + 1.0) * 0.5);
    return out;
}

// ---------- YUV → RGB ----------

struct YUVParams {
    uint fullRange;
    uint planar3;    // 1 = 三平面（U tex1.r, V tex2.r）；0 = NV12 双平面
    uint isRGB;      // 1 = texture0 已是 BGRA/RGBA
};

static inline float3 yuvToRGB(float y, float2 uv, bool fullRange) {
    if (fullRange) {
        float cb = uv.x - 0.5, cr = uv.y - 0.5;
        return float3(y + 1.5748 * cr,
                      y - 0.1873 * cb - 0.4681 * cr,
                      y + 1.8556 * cb);
    } else {
        float yy = (y - 16.0 / 255.0) * (255.0 / 219.0);
        float cb = (uv.x - 0.5) * (255.0 / 224.0);
        float cr = (uv.y - 0.5) * (255.0 / 224.0);
        return float3(yy + 1.5748 * cr,
                      yy - 0.1873 * cb - 0.4681 * cr,
                      yy + 1.8556 * cb);
    }
}

// ---------- 双平面/三平面取色 ----------

static inline float2 sampleChroma(texture2d<float> chroma,
                                  texture2d<float> chromaV,
                                  sampler smp, float2 uv,
                                  constant YUVParams &p) {
    if (p.planar3 == 1) {
        return float2(chroma.sample(smp, uv).r, chromaV.sample(smp, uv).r);
    }
    return chroma.sample(smp, uv).rg;
}

// ---------- 片元：Nearest / Bilinear（采样器区分）----------

fragment float4 fragmentSample(BlitVertexOut in [[stage_in]],
                               texture2d<float> srcY [[texture(0)]],
                               texture2d<float> srcC [[texture(1)]],
                               texture2d<float> srcV [[texture(2)]],
                               sampler smp [[sampler(0)]],
                               constant YUVParams &p [[buffer(0)]]) {
    if (p.isRGB != 0) {
        return srcY.sample(smp, in.uv);
    }
    float y = srcY.sample(smp, in.uv).r;
    float2 uv = sampleChroma(srcC, srcV, smp, in.uv, p);
    return float4(saturate(yuvToRGB(y, uv, p.fullRange != 0)), 1.0);
}

// ---------- 片元：Bicubic（YUV 各 16-tap）----------

fragment float4 fragmentBicubic(BlitVertexOut in [[stage_in]],
                                texture2d<float> luma [[texture(0)]],
                                texture2d<float> chroma [[texture(1)]],
                                texture2d<float> chromaV [[texture(2)]],
                                sampler smp [[sampler(0)]],
                                constant YUVParams &p [[buffer(0)]]) {
    if (p.isRGB != 0) {
        // RGB 输入：直接对 RGBA 16-tap
        uint2 dims = uint2(luma.get_width(), luma.get_height());
        float2 texPos = in.uv * float2(dims);
        float2 texPos1 = floor(texPos - 0.5) + 0.5;
        float2 f = texPos - texPos1;
        float4 wx = bicubicWeights(f.x);
        float4 wy = bicubicWeights(f.y);
        float4 acc = 0.0;
        for (int j = 0; j < 4; j++) {
            for (int i = 0; i < 4; i++) {
                float w = wx[i] * wy[j];
                float2 uv = (texPos1 + float2(i - 1, j - 1)) / float2(dims);
                acc += w * luma.sample(smp, uv);
            }
        }
        return float4(saturate(acc.rgb), 1.0);
    }
    uint2 dims = uint2(luma.get_width(), luma.get_height());
    float2 texPos = in.uv * float2(dims);
    float2 texPos1 = floor(texPos - 0.5) + 0.5;
    float2 f = texPos - texPos1;
    float4 wx = bicubicWeights(f.x);
    float4 wy = bicubicWeights(f.y);
    float y = 0.0;
    float2 uvAcc = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float w = wx[i] * wy[j];
            float2 uv = (texPos1 + float2(i - 1, j - 1)) / float2(dims);
            y += w * luma.sample(smp, uv).r;
            uvAcc += w * sampleChroma(chroma, chromaV, smp, uv, p);
        }
    }
    return float4(saturate(yuvToRGB(y, uvAcc, p.fullRange != 0)), 1.0);
}

// ---------- 片元：Lanczos-2 ----------

fragment float4 fragmentLanczos(BlitVertexOut in [[stage_in]],
                                texture2d<float> luma [[texture(0)]],
                                texture2d<float> chroma [[texture(1)]],
                                texture2d<float> chromaV [[texture(2)]],
                                sampler smp [[sampler(0)]],
                                constant YUVParams &p [[buffer(0)]]) {
    uint2 dims = uint2(luma.get_width(), luma.get_height());
    float2 texPos = in.uv * float2(dims);
    float2 center = floor(texPos - 0.5) + 0.5;
    float2 frac = texPos - center;

    float y = 0.0;
    float2 uvAcc = 0.0;
    float4 rgbAcc = 0.0;
    float wsum = 0.0;
    for (int j = -1; j <= 2; j++) {
        for (int i = -1; i <= 2; i++) {
            float wx = lanczos2(float(i) - 0.5 - frac.x + 0.5);
            float wy = lanczos2(float(j) - 0.5 - frac.y + 0.5);
            float w = wx * wy;
            if (w == 0.0) continue;
            float2 uv = (center + float2(i, j)) / float2(dims);
            wsum += w;
            if (p.isRGB != 0) {
                rgbAcc += w * luma.sample(smp, uv);
            } else {
                y += w * luma.sample(smp, uv).r;
                uvAcc += w * sampleChroma(chroma, chromaV, smp, uv, p);
            }
        }
    }
    if (wsum > 1e-6) {
        if (p.isRGB != 0) return float4(saturate((rgbAcc / wsum).rgb), 1.0);
        y /= wsum; uvAcc /= wsum;
    }
    return float4(saturate(yuvToRGB(y, uvAcc, p.fullRange != 0)), 1.0);
}

// ---------- Sharpen（unsharp mask，compute 后处理）----------

kernel void sharpenKernel(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float &amount [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    int2 p = int2(gid);
    int2 maxp = int2(int(src.get_width()) - 1, int(src.get_height()) - 1);
    float4 c = src.read(gid);
    float4 blur = (src.read(uint2(clamp(p + int2(-1, 0), int2(0), maxp))) +
                   src.read(uint2(clamp(p + int2(1, 0), int2(0), maxp))) +
                   src.read(uint2(clamp(p + int2(0, -1), int2(0), maxp))) +
                   src.read(uint2(clamp(p + int2(0, 1), int2(0), maxp)))) * 0.25;
    float4 sharp = c + (c - blur) * amount;
    dst.write(clamp(sharp, 0.0, 1.0), gid);
}
