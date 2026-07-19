//
//  Nvmm
//  ShaderTypes.h
//
//  Types shared between Swift/Metal host code and the Metal shaders. This is
//  the single source of truth for GPU buffer layouts: it is included by both
//  Shaders.metal and (through the bridging header) Swift, so a struct declared
//  here has an identical layout on both sides. Never redeclare these in Swift.
//
//  This currently defines only what the placeholder shader needs. The full set
//  of render structures (glyphs, lines, cursor, cell graphics) is not yet
//  defined.
//

#ifndef SHADER_TYPES_H
#define SHADER_TYPES_H

#include <simd/simd.h>

/// Per-frame uniforms. Will be expanded to carry cell metrics, baseline,
/// cursor state, and grid width.
typedef struct {
    simd_float2 pixel_size;
} NvmmUniforms;

#endif /* SHADER_TYPES_H */
