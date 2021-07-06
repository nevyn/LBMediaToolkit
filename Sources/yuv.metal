//
//  yuv.metal
//
//  Created by nevyn Bengtsson on 2019-04-03.
//

#include <metal_stdlib>
using namespace metal;

typedef struct {
  packed_float2 position;
  packed_float2 texcoord;
} Vertex;

typedef struct {
  float4 position[[position]];
  float2 texcoord;
} Varyings;

struct Uniforms{
  float4x4 modelMatrix;
};

vertex Varyings vertexPassthrough(
    const device Vertex * verticies [[buffer(0)]],
    const device Uniforms& uniforms [[buffer(1)]],
    unsigned int vid[[vertex_id]]
)
{
    Varyings out;
    const device Vertex &v = verticies[vid];
    out.position = uniforms.modelMatrix * float4(float2(v.position), 0.0, 1.0);
    out.texcoord = v.texcoord;
    return out;
}

fragment half4 yuvToRgba(
    Varyings in[[stage_in]],
    texture2d<float, access::sample> textureY[[texture(0)]],
    texture2d<float, access::sample> textureUV[[texture(1)]]
)
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float y;
    float2 uv;
    y = textureY.sample(s, in.texcoord).r;
    uv = textureUV.sample(s, in.texcoord).rg - float2(0.5, 0.5);

    // Conversion for YUV to rgb from http://www.fourcc.org/fccyvrgb.php
    float4 out = float4(y + 1.403 * uv.y, y - 0.344 * uv.x - 0.714 * uv.y, y + 1.770 * uv.x, 1.0);

    return half4(out);
}
