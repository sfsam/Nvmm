//
//  Nvmm
//  Shaders.metal
//
//  The grid render pipelines. Each frame draws, in order: cell backgrounds,
//  procedural cell graphics, glyphs, line decorations, the cursor, and an
//  optional cursor smear. Each pass draws four-vertex triangle strips. Vertex
//  data describes rectangles as an origin plus a size; a vertex offset selects
//  one of the four corners.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// The drawable uses gamma-encoded Display P3. Neovim colors arrive as sRGB,
// so every render pass converts them before writing or blending.
constant float3x3 sRGB_XYZ = transpose(float3x3(
    0.4360747, 0.3850649, 0.1430804,
    0.2225045, 0.7168786, 0.0606169,
    0.0139322, 0.0971045, 0.7141733
));
constant float3x3 XYZ_DP3 = transpose(float3x3(
     2.40414768, -0.99010704, -0.39759019,
    -0.84239098,  1.79905954,  0.01597023,
     0.04838763, -0.09752546,  1.27393636
));
constant float3x3 sRGB_DP3 = XYZ_DP3 * sRGB_XYZ;

float3 linearize_srgb(float3 color) {
    bool3 cutoff = color <= 0.04045;
    float3 lower = color / 12.92;
    float3 higher = pow((color + 0.055) / 1.055, float3(2.4));
    return mix(higher, lower, float3(cutoff));
}

float3 encode_srgb(float3 color) {
    bool3 cutoff = color <= 0.0031308;
    float3 lower = color * 12.92;
    float3 higher = pow(color, float3(1.0 / 2.4)) * 1.055 - 0.055;
    return mix(higher, lower, float3(cutoff));
}

float3 srgb_to_display_p3(float3 color) {
    return encode_srgb(sRGB_DP3 * linearize_srgb(color));
}

float4 load_color(uint32_t packed) {
    float4 color = unpack_unorm4x8_to_float(packed);
    color.rgb = srgb_to_display_p3(color.rgb);
    return color;
}

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
    float4 color;
    uint32_t texture_index;
    uint32_t atlas;
};

struct cell_graphic_rasterizer_data {
    float4 position [[position]];
    float2 cell_position;
    float2 cell_size;
    float4 color;
    float4 background_color;
    uint32_t kind;
};

struct cursor_smear_rasterizer_data {
    float4 position [[position]];
    float2 pixel_position;
    float4 previous_cursor;
    float4 current_cursor;
    float4 color;
    float progress;
    float corner_speed;
};

// Corner selectors for a rectangle given as origin + size. The vertex offset is
// the size vector multiplied by the selected transform.
constant float2 transforms[4] = {
    {0, 0}, // Top left
    {0, 1}, // Bottom left
    {1, 0}, // Top right
    {1, 1}, // Bottom right
};

// Keeps the transient effect vivid without changing the authoritative cursor.
constant float cursor_smear_saturation = 1.8;

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
    data.color = load_color(cell_colors[instance_id]);
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
    data.color = load_color(uniforms.cursor_color);
    return data;
}

vertex cursor_smear_rasterizer_data
cursor_smear_render(uint vertex_id [[vertex_id]],
                    constant uniform_data &uniforms [[buffer(0)]],
                    constant cursor_smear_data *smears [[buffer(1)]]) {
    constant cursor_smear_data &smear = smears[0];
    // Shorter profiles move the effective source toward the destination.
    float4 previous = mix(smear.current_cursor, smear.previous_cursor,
                          smear.length_fraction);
    // Two pixels contain the one-pixel antialiasing ramp at either boundary.
    float2 bounds_min = min(previous.xy, smear.current_cursor.xy) - 2.0;
    float2 bounds_max = max(previous.xy + previous.zw,
                            smear.current_cursor.xy + smear.current_cursor.zw)
                        + 2.0;
    float2 pixel_position = bounds_min
        + (bounds_max - bounds_min) * transforms[vertex_id];
    float2 position = float2(-1, 1) + pixel_position * uniforms.pixel_size;

    float4 color = unpack_unorm4x8_to_float(smear.color);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = clamp(mix(float3(gray), color.rgb,
                          cursor_smear_saturation), 0.0, 1.0);
    color.rgb = srgb_to_display_p3(color.rgb);
    color.a = smear.opacity;

    cursor_smear_rasterizer_data data;
    data.position = float4(position, 0, 1);
    data.pixel_position = pixel_position;
    data.previous_cursor = previous;
    data.current_cursor = smear.current_cursor;
    data.color = color;
    data.progress = smear.progress;
    data.corner_speed = smear.corner_speed;
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
        float4 color = load_color(line.color);
        data.color = float4(color.rgb, line_offset.y + line.thickness * 0.5);
        data.period = -uniforms.cell_pixel_size.x;
        data.pattern_size = uniforms.cell_pixel_size.x;
        data.center_y = line_offset.y + line.thickness * 0.5;
        data.thickness = line.thickness;
        data.style = 0;
    } else {
        float line_position = line.count + transforms[vertex_id].x;
        float period = uniforms.cell_pixel_size.x * line_position / line.period;
        data.color = load_color(line.color);
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

    // Limit ink overhang to one neighboring cell or row on each side.
    float glyph_min_x = -uniforms.cell_pixel_size.x;
    float glyph_max_x = uniforms.cell_pixel_size.x * (glyph.cell_width + 1);
    float glyph_min_y = -uniforms.cell_pixel_size.y;
    float glyph_max_y = uniforms.cell_pixel_size.y * 2.0;
    float glyph_x = clamp(glyph_offset_raw.x, glyph_min_x, glyph_max_x);
    float glyph_y = clamp(glyph_offset_raw.y, glyph_min_y, glyph_max_y);
    float2 glyph_offset = float2(glyph_x, glyph_y);

    // If the glyph was cropped, crop the texture quad to match.
    float2 texture_offset = vertex_offset - (glyph_offset_raw - glyph_offset);

    float2 pixel_position = cell_position + glyph_offset;
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    glyph_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.texture_position = float2(glyph.rect.texture_origin.xy) + texture_offset;
    data.color = load_color(glyph.foreground_color);
    data.texture_index = glyph.rect.texture_origin.z;
    data.atlas = glyph.atlas;
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
    data.color = load_color(graphic.color);
    data.background_color = load_color(graphic.background_color);
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
                           texture2d_array<float> masks [[texture(0)]],
                           texture2d_array<float> colors [[texture(1)]]) {
    constexpr sampler texture_sampler(mag_filter::nearest,
                                      min_filter::nearest,
                                      address::clamp_to_zero,
                                      coord::pixel);

    if (in.atlas == 0) {
        float coverage = masks.sample(
            texture_sampler, in.texture_position, in.texture_index).r;
        return float4(in.color.rgb * coverage, coverage);
    }

    // The color atlas is already premultiplied, gamma-encoded Display P3.
    return colors.sample(texture_sampler, in.texture_position, in.texture_index);
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

struct cursor_quad {
    float2 top_left;
    float2 top_right;
    float2 bottom_left;
    float2 bottom_right;
};

cursor_quad make_cursor_quad(float2 position, float2 size) {
    cursor_quad quad;
    quad.top_left = position;
    quad.top_right = position + float2(size.x, 0);
    quad.bottom_left = position - float2(0, size.y);
    quad.bottom_right = position + float2(size.x, -size.y);
    return quad;
}

void select_trail_corners(cursor_quad quad, float2 selector,
                          thread float2 &p1, thread float2 &p2,
                          thread float2 &p3) {
    p1 = mix(mix(quad.top_right, quad.top_left, selector.x),
             mix(quad.bottom_right, quad.bottom_left, selector.x),
             selector.y);
    p2 = mix(mix(quad.top_left, quad.bottom_left, selector.x),
             mix(quad.top_right, quad.bottom_right, selector.x),
             selector.y);
    p3 = mix(mix(quad.bottom_right, quad.top_right, selector.x),
             mix(quad.bottom_left, quad.top_left, selector.x),
             selector.y);
}

void select_cursor_corners(cursor_quad quad, float2 selector,
                           thread float2 &p1, thread float2 &p2,
                           thread float2 &p3, thread float2 &p4) {
    select_trail_corners(quad, selector, p1, p2, p3);
    p4 = mix(mix(quad.bottom_left, quad.bottom_right, selector.x),
             mix(quad.top_left, quad.top_right, selector.x), selector.y);
}

void cursor_smear_edge(float2 point, float2 first, float2 second,
                       thread float &minimum_distance,
                       thread float &inside) {
    float2 edge = second - first;
    float2 offset = point - first;
    float length_squared = max(dot(edge, edge), 1e-6);
    float position = clamp(dot(offset, edge) / length_squared, 0.0, 1.0);
    float2 difference = offset - edge * position;
    minimum_distance = min(minimum_distance, dot(difference, difference));
    float cross_product = edge.x * offset.y - edge.y * offset.x;
    inside = min(inside, step(0.0, cross_product));
}

float cursor_smear_hexagon_distance(float2 point, float2 p0, float2 p1,
                                    float2 p2, float2 p3, float2 p4,
                                    float2 p5) {
    float minimum_distance = 1e20;
    float inside = 1.0;
    cursor_smear_edge(point, p0, p1, minimum_distance, inside);
    cursor_smear_edge(point, p1, p2, minimum_distance, inside);
    cursor_smear_edge(point, p2, p3, minimum_distance, inside);
    cursor_smear_edge(point, p3, p4, minimum_distance, inside);
    cursor_smear_edge(point, p4, p5, minimum_distance, inside);
    cursor_smear_edge(point, p5, p0, minimum_distance, inside);
    float distance = sqrt(max(minimum_distance, 0.0));
    return mix(distance, -distance, inside);
}

float cursor_rectangle_distance(float2 point, float2 center,
                                float2 half_size) {
    float2 distance = abs(point - center) - half_size;
    return length(max(distance, 0.0))
        + min(max(distance.x, distance.y), 0.0);
}

float cursor_smear_ease(float progress) {
    float remaining = 1.0 - clamp(progress, 0.0, 1.0);
    return 1.0 - remaining * remaining * remaining;
}

fragment float4
cursor_smear_fill(cursor_smear_rasterizer_data in [[stage_in]]) {
    // Corner selection uses a bottom-left coordinate system. Negating y keeps
    // its polygon vertices counter-clockwise for the edge tests below.
    float2 point = float2(in.pixel_position.x, -in.pixel_position.y);
    float2 current_position =
        float2(in.current_cursor.x, -in.current_cursor.y);
    float2 previous_position =
        float2(in.previous_cursor.x, -in.previous_cursor.y);
    cursor_quad current = make_cursor_quad(current_position,
                                           in.current_cursor.zw);
    cursor_quad previous = make_cursor_quad(previous_position,
                                            in.previous_cursor.zw);
    float2 selector = step(float2(0), current_position - previous_position);

    float2 current_p1, current_p2, current_p3, current_p4;
    float2 previous_p1, previous_p2, previous_p3;
    select_cursor_corners(current, selector, current_p1, current_p2,
                          current_p3, current_p4);
    select_trail_corners(previous, selector, previous_p1, previous_p2,
                         previous_p3);

    float progress = cursor_smear_ease(in.progress);
    // Three corners arrive early, leaving one corner to trail behind.
    float corner_progress = cursor_smear_ease(
        min(in.progress * in.corner_speed, 1.0));
    float2 trail_p1 = mix(previous_p1, current_p1, progress);
    float2 trail_p2 = mix(previous_p2, current_p2, corner_progress);
    float2 trail_p3 = mix(previous_p3, current_p3, corner_progress);

    float distance = cursor_smear_hexagon_distance(
        point, trail_p1, trail_p2, current_p2, current_p4, current_p3,
        trail_p3);
    float alpha = 1.0 - smoothstep(-1.0, 1.0, distance);

    float2 half_size = in.current_cursor.zw * 0.5;
    float2 current_center = current_position
        + float2(half_size.x, -half_size.y);
    // The authoritative cursor is already present beneath this overlay.
    if (cursor_rectangle_distance(point, current_center, half_size) <= 0.0) {
        discard_fragment();
    }
    return float4(in.color.rgb, alpha * in.color.a);
}
