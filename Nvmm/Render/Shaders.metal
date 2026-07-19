//
//  Nvmm
//  Shaders.metal
//
//  Placeholder shader. Verifies that the Metal toolchain builds and that the
//  shared ShaderTypes.h header is visible to the Metal compiler. The real
//  background, glyph, line, cursor, and cell-graphic pipelines are not yet
//  implemented.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct RasterData {
    float4 position [[position]];
};

vertex RasterData nvmm_passthrough_vertex(uint vertex_id [[vertex_id]],
                                          constant NvmmUniforms &uniforms [[buffer(0)]]) {
    // A degenerate full-screen triangle. Currently unused; present only so the
    // pipeline and ShaderTypes.h bridge compile.
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0),
    };

    RasterData out;
    out.position = float4(positions[vertex_id], 0.0, 1.0);
    (void)uniforms;
    return out;
}

fragment float4 nvmm_passthrough_fragment(RasterData in [[stage_in]]) {
    (void)in;
    return float4(0.0, 0.0, 0.0, 1.0);
}
