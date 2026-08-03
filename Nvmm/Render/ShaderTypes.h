//
//  Nvmm
//  ShaderTypes.h
//
//  Types shared between Swift/Metal host code and the Metal shaders. This is
//  the single source of truth for GPU buffer layouts: it is included by both
//  Shaders.metal and (through the bridging header) Swift, so a struct declared
//  here has an identical layout on both sides. Never redeclare these in Swift.
//
//  The structs are plain C aggregates with no methods, so Swift imports them
//  directly and fills their fields; the shaders only read them.
//

#ifndef SHADER_TYPES_H
#define SHADER_TYPES_H

#include <simd/simd.h>

/// Per-frame values constant across a draw. Coordinates are in the drawable's
/// backing pixels unless noted otherwise.
typedef struct {
    /// Scales a pixel position into Metal clip space. x is 2/width, y is
    /// -2/height so that increasing pixel-y moves down the screen.
    simd_float2 pixel_size;

    /// The size of a single-width cell in backing pixels.
    simd_float2 cell_pixel_size;

    /// The size of a single-width cell in clip space (cell_pixel_size scaled by
    /// pixel_size).
    simd_float2 cell_size;

    /// The translation from a cell's top-left corner to the font baseline.
    simd_float2 baseline;

    /// The cursor cell position (x = column, y = row).
    simd_short2 cursor_position;

    /// The cursor color as packed RGBA bytes (low byte red).
    uint32_t cursor_color;

    /// The thickness in pixels of the cursor's bar and outline shapes.
    uint32_t cursor_line_width;

    /// The cursor cell width in cells (1 or 2).
    uint32_t cursor_cell_width;

    /// The grid width in cells, used to map a background instance to a cell.
    uint32_t grid_width;
} uniform_data;

/// A rasterized glyph stored in a texture cache page.
typedef struct {
    /// The size of the glyph's bounding rect in pixels.
    simd_short2 size;

    /// Translation from the font baseline to the glyph's top-left corner.
    simd_short2 position;

    /// The glyph's location in the texture cache:
    ///   x - the x pixel coordinate of the top-left corner,
    ///   y - the y pixel coordinate of the top-left corner,
    ///   z - the cache page (texture array slice).
    simd_short3 texture_origin;
} glyph_rect;

/// One glyph draw: where to place a cached glyph on the grid.
typedef struct {
    simd_short2 grid_position;
    uint32_t cell_width;
    /// Foreground color as packed RGBA bytes (low byte red).
    uint32_t foreground_color;
    /// 0 for a one-channel coverage mask, 1 for premultiplied RGBA.
    uint32_t atlas;
    glyph_rect rect;
} glyph_data;

/// One procedurally-drawn cell graphic (block/shade/diagonal fills) that the
/// fragment shader renders without a glyph texture.
typedef struct {
    simd_short2 grid_position;
    uint32_t cell_width;
    uint32_t color;
    uint32_t background_color;
    uint32_t kind;
} cell_graphic_data;

/// The shape of a line decoration, independent of grid position.
typedef struct {
    /// The line's y position as an offset from the font baseline.
    int16_t ytranslate;

    /// The pattern period for patterned lines; 0 for solid lines.
    uint16_t period;

    /// The line's thickness in pixels.
    uint16_t thickness;

    /// 0 = solid, 1 = dashed, 2 = dotted.
    uint16_t style;
} line_metrics;

/// One underline, undercurl, overline, or strikethrough segment. A segment is
/// one cell wide; adjacent segments join into a continuous line. The color's
/// high byte carries opacity; the low three bytes are RGB.
typedef struct {
    simd_short2 grid_position;
    uint32_t color;
    int16_t ytranslate;
    uint16_t period;
    uint16_t thickness;

    /// The cell's zero-based index within the overall line, used to keep dotted
    /// and dashed patterns continuous across cells.
    uint16_t count;
    uint16_t style;
} line_data;

#endif /* SHADER_TYPES_H */
