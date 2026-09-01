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

    /// The light box-drawing stroke width in backing pixels, already
    /// capped to a third of the cell. Heavy strokes are twice this.
    uint32_t box_line_width;

    /// The translation from a cell's top-left corner to the font baseline.
    simd_float2 baseline;

    /// The cursor cell position (x = column, y = row).
    simd_short2 cursor_position;

    /// The cursor color as packed RGBA bytes (low byte red).
    uint32_t cursor_color;

    /// The thickness in pixels of the cursor's bar and outline shapes.
    uint32_t cursor_line_width;

    /// The cursor height and its inset from the top of a line, in pixels.
    uint32_t cursor_height;
    uint32_t cursor_top;

    /// The cursor cell width in cells (1 or 2).
    uint32_t cursor_cell_width;

    /// The grid width in cells, used to map a background instance to a cell.
    uint32_t grid_width;

    /// 1 when a block cursor sits inside a ligature, so the glyph pass shows
    /// the cursor cell's own character in place of the ligature's ink there.
    uint32_t cursor_xray;
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

    /// Bit 0 (`GLYPH_FLAG_XRAY`) marks the cursor cell's own character, drawn
    /// only within the cursor rect. Every other glyph is instead hidden there.
    uint32_t flags;
} glyph_data;

/// `glyph_data.flags`: this glyph is the block cursor's x-ray character.
#define GLYPH_FLAG_XRAY 1u

/// Fixed cell-graphic kinds.
#define CELL_GRAPHIC_FULL_BLOCK 1u
#define CELL_GRAPHIC_DARK_SHADE 2u
#define CELL_GRAPHIC_MEDIUM_SHADE 3u
#define CELL_GRAPHIC_LIGHT_SHADE 4u
#define CELL_GRAPHIC_DIAGONAL_DOWN_LEFT 5u
#define CELL_GRAPHIC_DIAGONAL_DOWN_RIGHT 6u
#define CELL_GRAPHIC_DIAGONAL_CROSS 7u

/// Families encoded in the high four bits of `cell_graphic_data.kind`.
#define CELL_GRAPHIC_FAMILY_MASK 0xF0000000u
#define CELL_GRAPHIC_BOX_SEGMENTS 0x10000000u
#define CELL_GRAPHIC_BOX_DASHED 0x20000000u
#define CELL_GRAPHIC_BOX_ARC 0x30000000u

/// Two-bit box stroke styles.
#define CELL_GRAPHIC_STROKE_NONE 0u
#define CELL_GRAPHIC_STROKE_LIGHT 1u
#define CELL_GRAPHIC_STROKE_HEAVY 2u
#define CELL_GRAPHIC_STROKE_DOUBLE 3u
#define CELL_GRAPHIC_STROKE_MASK 3u

/// Directional stroke shifts in a box-segment payload.
#define CELL_GRAPHIC_BOX_UP_SHIFT 0u
#define CELL_GRAPHIC_BOX_RIGHT_SHIFT 2u
#define CELL_GRAPHIC_BOX_DOWN_SHIFT 4u
#define CELL_GRAPHIC_BOX_LEFT_SHIFT 6u

/// Dashed-line payload fields.
#define CELL_GRAPHIC_DASH_VERTICAL 1u
#define CELL_GRAPHIC_DASH_HEAVY 2u
#define CELL_GRAPHIC_DASH_COUNT_SHIFT 2u

/// Rounded-corner payload values.
#define CELL_GRAPHIC_ARC_DOWN_RIGHT 0u
#define CELL_GRAPHIC_ARC_DOWN_LEFT 1u
#define CELL_GRAPHIC_ARC_UP_LEFT 2u
#define CELL_GRAPHIC_ARC_UP_RIGHT 3u

/// One procedurally-drawn cell graphic (block, shade, diagonal, or separator)
/// that the fragment shader renders without a glyph texture.
typedef struct {
    simd_short2 grid_position;
    uint32_t cell_width;
    uint32_t color;
    uint32_t background_color;
    uint32_t cursor_color;
    uint32_t cursor_background_color;
    uint32_t kind;
    uint32_t flags;
} cell_graphic_data;

/// `cell_graphic_data.flags`: recolor inside the block cursor rectangle.
#define CELL_GRAPHIC_FLAG_CURSOR 1u

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

/// One animated cursor smear. Rectangles are x, y, width, height in drawable
/// pixels, with a top-left origin.
typedef struct {
    simd_float4 previous_cursor;
    simd_float4 current_cursor;
    uint32_t color;
    float progress;
    float length_fraction;
    float opacity;
    float corner_speed;
} cursor_smear_data;

#endif /* SHADER_TYPES_H */
