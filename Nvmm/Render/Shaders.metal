//
//  Nvmm
//  Shaders.metal
//
//  The grid render pipelines. Each frame draws, in order: cell backgrounds,
//  procedural cell graphics, glyphs, line decorations, and the cursor. Every
//  pipeline is instanced: one instance per cell, glyph, graphic, or line, each
//  drawn as a four-vertex triangle strip. Vertex data describes rectangles as
//  an origin plus a size; a vertex offset selects one of the four corners.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct grid_rasterizer_data {
    float4 position [[position]];
    float4 color;
};

struct line_rasterizer_data {
    float4 position [[position]];
    float4 color;
    float period;
    float pattern_size;
    float center_y;
    float thickness;
    float style;
};

struct glyph_rasterizer_data {
    float4 position [[position]];
    float2 texture_position;
    uint32_t texture_index;
};

struct cell_graphic_rasterizer_data {
    float4 position [[position]];
    float2 cell_position;
    float2 cell_size;
    float4 color;
    float4 background_color;
    uint32_t kind;
};

// Corner selectors for a rectangle given as origin + size. The vertex offset is
// the size vector multiplied by the selected transform.
constant float2 transforms[4] = {
    {0, 0}, // Top left
    {0, 1}, // Bottom left
    {1, 0}, // Top right
    {1, 1}, // Bottom right
};

// Per-shape corner nudges that carve a thin bar out of a full cell rect. Row 0
// is a right-anchored vertical bar, row 1 a bottom-anchored horizontal bar,
// row 2 a left-anchored vertical bar, row 3 a top-anchored horizontal bar.
// Drawing all four produces a block outline.
constant float2 cursor_transforms[5][4] = {
    {{ 0,  0}, { 0,  0}, { 1,  0}, { 1,  0}},
    {{ 0, -1}, { 0,  0}, { 0, -1}, { 0,  0}},
    {{ 0,  0}, { 0,  1}, { 0,  0}, { 0,  1}},
    {{-1,  0}, {-1,  0}, { 0,  0}, { 0,  0}},
};

vertex grid_rasterizer_data
background_render(uint vertex_id [[vertex_id]],
                  uint instance_id [[instance_id]],
                  constant uniform_data &uniforms [[buffer(0)]],
                  constant uint32_t *cell_colors [[buffer(1)]]) {
    uint32_t row = instance_id / uniforms.grid_width;
    uint32_t col = instance_id % uniforms.grid_width;

    float2 cell_vertex = float2(col, row) + transforms[vertex_id];
    float2 position = float2(-1, 1) + (uniforms.cell_size * cell_vertex);

    grid_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.color = unpack_unorm4x8_srgb_to_float(cell_colors[instance_id]);
    return data;
}

/// Renders the cursor. The shape is selected by instance_id:
///   0. A right-anchored vertical bar.
///   1. A bottom-anchored horizontal bar.
///   2. A left-anchored vertical bar.
///   3. A top-anchored horizontal bar.
/// Draw all four instances to make a block outline.
vertex grid_rasterizer_data
cursor_render(uint vertex_id [[vertex_id]],
              uint instance_id [[instance_id]],
              constant uniform_data &uniforms [[buffer(0)]]) {
    // The cursor cell size in pixels, accounting for a double-width cell.
    float2 cell_pixel_size = uniforms.cell_pixel_size;
    cell_pixel_size.x *= uniforms.cursor_cell_width;

    // The cursor cell's top-left corner in pixel coordinates.
    float2 cell_position =
        float2(uniforms.cursor_position.xy) * uniforms.cell_pixel_size;

    // This vertex in pixel coordinates.
    float2 cell_vertex = cell_position + (cell_pixel_size * transforms[vertex_id]);

    // To draw a bar we start with the cell rect and subtract an inner rect so
    // the remainder is the bar of the required size and position.
    float2 base_translation = cell_pixel_size - float2(uniforms.cursor_line_width);
    float2 translate = base_translation * cursor_transforms[instance_id][vertex_id];

    float2 pixel_position = cell_vertex - translate;
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    grid_rasterizer_data data;
    data.position = float4(position.xy, 0.0, 1.0);
    data.color = unpack_unorm4x8_srgb_to_float(uniforms.cursor_color);
    return data;
}

vertex line_rasterizer_data
line_render(uint vertex_id [[vertex_id]],
            uint instance_id [[instance_id]],
            constant uniform_data &uniforms [[buffer(0)]],
            constant line_data *lines [[buffer(1)]]) {
    constant line_data &line = lines[instance_id];
    int16_t row = line.grid_position.y;
    int16_t col = line.grid_position.x;

    // A line is one cell wide; its height is its thickness.
    float2 line_size = float2(uniforms.cell_pixel_size.x, line.thickness);

    // The line's top-left corner in pixel coordinates.
    float2 line_offset = uniforms.cell_pixel_size * float2(col, row);
    line_offset.y += uniforms.baseline.y - line.ytranslate;

    float2 pixel_position = line_offset + (line_size * transforms[vertex_id]);
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    line_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);

    // period == 0xFFFF is the undercurl sentinel. Encode the wave's center y in
    // color.a and the cell width as a negative period; line_fill detects an
    // undercurl by period < 0.
    if (line.period == 0xFFFF) {
        float4 color = unpack_unorm4x8_srgb_to_float(line.color);
        data.color = float4(color.rgb, line_offset.y + line.thickness * 0.5);
        data.period = -uniforms.cell_pixel_size.x;
        data.pattern_size = uniforms.cell_pixel_size.x;
        data.center_y = line_offset.y + line.thickness * 0.5;
        data.thickness = line.thickness;
        data.style = 0;
    } else {
        float line_position = line.count + transforms[vertex_id].x;
        float period = uniforms.cell_pixel_size.x * line_position / line.period;
        data.color = unpack_unorm4x8_srgb_to_float(line.color);
        data.period = select(0.5, period, line.period);
        data.pattern_size = line.period;
        data.center_y = line_offset.y + line.thickness * 0.5;
        data.thickness = line.thickness;
        data.style = line.style;
    }

    return data;
}

vertex glyph_rasterizer_data
glyph_render(uint vertex_id [[vertex_id]],
             uint instance_id [[instance_id]],
             constant uniform_data &uniforms [[buffer(0)]],
             constant glyph_data *glyphs [[buffer(1)]]) {
    constant glyph_data &glyph = glyphs[instance_id];
    int16_t col = glyph.grid_position.x;
    int16_t row = glyph.grid_position.y;

    // The cell's top-left corner in pixel coordinates.
    float2 cell_position = uniforms.cell_pixel_size * float2(col, row);

    float2 glyph_position = float2(glyph.rect.position.xy);
    float2 glyph_size = float2(glyph.rect.size.xy);
    float2 vertex_offset = glyph_size * transforms[vertex_id];

    // From the cell's top-left corner: move to the baseline, then to the glyph
    // position, then apply the vertex offset.
    float2 glyph_offset_raw = uniforms.baseline + glyph_position + vertex_offset;

    // Clamp so we never draw outside the cell (double-width cells are wider).
    float2 cell_bounds = float2(uniforms.cell_pixel_size.x * glyph.cell_width,
                                uniforms.cell_pixel_size.y);

    float2 glyph_offset = clamp(glyph_offset_raw, float2(0, 0), cell_bounds);

    // If the glyph was cropped, crop the texture quad to match.
    float2 texture_offset = vertex_offset - (glyph_offset_raw - glyph_offset);

    float2 pixel_position = cell_position + glyph_offset;
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    glyph_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.texture_position = float2(glyph.rect.texture_origin.xy) + texture_offset;
    data.texture_index = glyph.rect.texture_origin.z;
    return data;
}

vertex cell_graphic_rasterizer_data
cell_graphic_render(uint vertex_id [[vertex_id]],
                    uint instance_id [[instance_id]],
                    constant uniform_data &uniforms [[buffer(0)]],
                    constant cell_graphic_data *graphics [[buffer(1)]]) {
    constant cell_graphic_data &graphic = graphics[instance_id];
    int16_t col = graphic.grid_position.x;
    int16_t row = graphic.grid_position.y;

    float2 cell_position = uniforms.cell_pixel_size * float2(col, row);
    float2 cell_size = uniforms.cell_pixel_size;
    cell_size.x *= graphic.cell_width;
    float2 draw_position = cell_position;
    float2 draw_size = cell_size;

    // Pad diagonal graphics slightly so adjacent cells' lines meet.
    if (graphic.kind == 5 || graphic.kind == 6) {
        float pad = max(1.0, min(cell_size.x, cell_size.y) * 0.08);
        draw_position -= float2(pad);
        draw_size += float2(pad * 2.0);
    }

    float2 pixel_position = draw_position + (draw_size * transforms[vertex_id]);
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    cell_graphic_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.cell_position = cell_position;
    data.cell_size = cell_size;
    data.color = unpack_unorm4x8_srgb_to_float(graphic.color);
    data.background_color = unpack_unorm4x8_srgb_to_float(graphic.background_color);
    data.kind = graphic.kind;
    return data;
}

fragment float4 background_fill(grid_rasterizer_data in [[stage_in]]) {
    return in.color;
}

fragment float4 line_fill(line_rasterizer_data in [[stage_in]]) {
    if (in.period < 0) { // undercurl - see line_render above
        float wavelength = -in.period;
        float wave_center_y = in.color.a;
        float amplitude = wavelength * 0.08;
        float wave_y =
            wave_center_y + amplitude * sinpi(4.0 * in.position.x / wavelength);
        float dist = abs(in.position.y - wave_y);
        float alpha = 1.0 - smoothstep(0.75, 2.0, dist);
        if (alpha <= 0.0) discard_fragment();
        return float4(in.color.rgb, alpha);
    }

    if (in.style > 1.5) { // dotted
        float radius = max(1.5, min(in.pattern_size * 0.22, in.thickness * 0.5));
        float x = (fract(in.period) - 0.5) * in.pattern_size;
        float y = in.position.y - in.center_y;
        float dist = length(float2(x, y));
        float alpha = 1.0 - smoothstep(radius - 0.5, radius + 0.5, dist);
        if (alpha <= 0.0) discard_fragment();
        return float4(in.color.rgb, alpha * in.color.a);
    }

    return float4(in.color.rgb,
                  in.color.a * select(0.0, 1.0, sinpi(in.period) > 0));
}

fragment float4 glyph_fill(glyph_rasterizer_data in [[stage_in]],
                           texture2d_array<float> texture [[texture(0)]]) {
    constexpr sampler texture_sampler(mag_filter::nearest,
                                      min_filter::nearest,
                                      address::clamp_to_zero,
                                      coord::pixel);

    return texture.sample(texture_sampler, in.texture_position, in.texture_index);
}

fragment float4 cell_graphic_fill(cell_graphic_rasterizer_data in [[stage_in]]) {
    constexpr uint32_t full_block = 1;
    constexpr uint32_t dark_shade = 2;
    constexpr uint32_t medium_shade = 3;
    constexpr uint32_t light_shade = 4;
    constexpr uint32_t diagonal_upper_right_to_lower_left = 5;
    constexpr uint32_t diagonal_upper_left_to_lower_right = 6;

    if (in.kind == full_block) {
        return float4(in.color.rgb, 1.0);
    }

    if (in.kind == dark_shade ||
        in.kind == medium_shade ||
        in.kind == light_shade) {
        float coverage = 0.0;

        if (in.kind == dark_shade) {
            coverage = 0.57;
        } else if (in.kind == medium_shade) {
            coverage = 0.26;
        } else {
            coverage = 0.08;
        }

        return float4(mix(in.background_color.rgb, in.color.rgb, coverage), 1.0);
    }

    float2 local = in.position.xy - in.cell_position;
    float width = in.cell_size.x;
    float height = in.cell_size.y;
    float diagonal_length = length(in.cell_size);
    float dist = 0.0;

    if (in.kind == diagonal_upper_right_to_lower_left) {
        dist = abs(local.x * height + local.y * width - width * height) /
               diagonal_length;
    } else if (in.kind == diagonal_upper_left_to_lower_right) {
        dist = abs(local.x * height - local.y * width) / diagonal_length;
    } else {
        discard_fragment();
    }

    float thickness = max(0.65, min(width, height) * 0.045);
    float alpha = 1.0 - smoothstep(thickness, thickness + 0.85, dist);
    if (alpha <= 0.0) discard_fragment();

    return float4(in.color.rgb, alpha);
}
