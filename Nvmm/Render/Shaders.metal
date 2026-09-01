//
//  Nvmm
//  Shaders.metal
//
//  The grid render pipelines. Each frame draws, in order: cell backgrounds,
//  the block cursor, procedural cell graphics, glyphs, line decorations, other
//  cursor shapes, and an optional cursor smear. Each pass draws four-vertex
//  triangle strips. Vertex data describes rectangles as an origin plus a size;
//  a vertex offset selects one of the four corners.
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
    float2 pixel_position;
    float4 color;
    uint32_t texture_index;
    uint32_t atlas;
    uint32_t flags;
};

struct cell_graphic_rasterizer_data {
    float4 position [[position]];
    // Every field below is constant across the instance's quad.
    float2 cell_position [[flat]];
    float2 cell_size [[flat]];
    float4 color [[flat]];
    float4 background_color [[flat]];
    float4 cursor_color [[flat]];
    float4 cursor_background_color [[flat]];
    float box_line_width [[flat]];
    uint32_t kind;
    uint32_t flags [[flat]];
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

// Maps a position in drawable pixels, with a top-left origin, into clip space.
static float4 clip_position(constant uniform_data &uniforms, float2 pixel) {
    return float4(float2(-1, 1) + pixel * uniforms.pixel_size, 0, 1);
}

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
// is a left vertical bar, row 1 a bottom horizontal bar, row 2 a top horizontal
// bar, row 3 a right vertical bar, and row 4 the complete rect. Drawing the
// first four produces a block outline.
constant float2 cursor_transforms[5][4] = {
    {{ 0,  0}, { 0,  0}, { 1,  0}, { 1,  0}},
    {{ 0, -1}, { 0,  0}, { 0, -1}, { 0,  0}},
    {{ 0,  0}, { 0,  1}, { 0,  0}, { 0,  1}},
    {{-1,  0}, {-1,  0}, { 0,  0}, { 0,  0}},
    {{ 0,  0}, { 0,  0}, { 0,  0}, { 0,  0}},
};

static float4 cursor_pixel_rect(constant uniform_data &uniforms) {
    float2 origin =
        float2(uniforms.cursor_position.xy) * uniforms.cell_pixel_size;
    origin.y += uniforms.cursor_top;
    float2 size = float2(
        uniforms.cell_pixel_size.x * float(uniforms.cursor_cell_width),
        uniforms.cursor_height);
    return float4(origin, size);
}

vertex grid_rasterizer_data
background_render(uint vertex_id [[vertex_id]],
                  uint instance_id [[instance_id]],
                  constant uniform_data &uniforms [[buffer(0)]],
                  constant uint32_t *cell_colors [[buffer(1)]]) {
    uint32_t row = instance_id / uniforms.grid_width;
    uint32_t col = instance_id % uniforms.grid_width;

    float2 cell_vertex = float2(col, row) + transforms[vertex_id];

    grid_rasterizer_data data;
    data.position = clip_position(uniforms,
                                  uniforms.cell_pixel_size * cell_vertex);
    data.color = load_color(cell_colors[instance_id]);
    return data;
}

/// Renders the cursor. The shape is selected by instance_id:
///   0. A left vertical bar.
///   1. A bottom horizontal bar.
///   2. A top horizontal bar.
///   3. A right vertical bar.
///   4. A complete block.
/// Draw all four instances to make a block outline.
vertex grid_rasterizer_data
cursor_render(uint vertex_id [[vertex_id]],
              uint instance_id [[instance_id]],
              constant uniform_data &uniforms [[buffer(0)]]) {
    // The cursor cell size in pixels, accounting for a double-width cell.
    float4 cursor_rect = cursor_pixel_rect(uniforms);
    float2 cell_position = cursor_rect.xy;
    float2 cell_pixel_size = cursor_rect.zw;

    // This vertex in pixel coordinates.
    float2 cell_vertex = cell_position + (cell_pixel_size * transforms[vertex_id]);

    // To draw a bar we start with the cell rect and subtract an inner rect so
    // the remainder is the bar of the required size and position.
    float2 base_translation = cell_pixel_size - float2(uniforms.cursor_line_width);
    float2 translate = base_translation * cursor_transforms[instance_id][vertex_id];

    float2 pixel_position = cell_vertex - translate;

    grid_rasterizer_data data;
    data.position = clip_position(uniforms, pixel_position);
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

    float4 color = unpack_unorm4x8_to_float(smear.color);
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = clamp(mix(float3(gray), color.rgb,
                          cursor_smear_saturation), 0.0, 1.0);
    color.rgb = srgb_to_display_p3(color.rgb);
    color.a = smear.opacity;

    cursor_smear_rasterizer_data data;
    data.position = clip_position(uniforms, pixel_position);
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

    line_rasterizer_data data;
    data.position = clip_position(uniforms, pixel_position);

    // period == 0xFFFF is the undercurl sentinel, carried to line_fill as the
    // cell width negated: it detects an undercurl by period < 0 and needs no
    // other shape data.
    if (line.period == 0xFFFF) {
        data.color = load_color(line.color);
        data.period = -uniforms.cell_pixel_size.x;
        data.pattern_size = 0;
        data.center_y = line_offset.y + line.thickness * 0.5;
        data.thickness = 0;
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
    float2 glyph_max = uniforms.cell_pixel_size
        * float2(float(glyph.cell_width) + 1.0, 2.0);
    float2 glyph_offset = clamp(glyph_offset_raw,
                                -uniforms.cell_pixel_size, glyph_max);

    // If the glyph was cropped, crop the texture quad to match.
    float2 texture_offset = vertex_offset - (glyph_offset_raw - glyph_offset);

    float2 pixel_position = cell_position + glyph_offset;

    glyph_rasterizer_data data;
    data.position = clip_position(uniforms, pixel_position);
    data.texture_position = float2(glyph.rect.texture_origin.xy) + texture_offset;
    data.pixel_position = pixel_position;
    data.color = load_color(glyph.foreground_color);
    data.texture_index = glyph.rect.texture_origin.z;
    data.atlas = glyph.atlas;
    data.flags = glyph.flags;
    return data;
}

static bool is_diagonal(uint32_t kind) {
    return kind == CELL_GRAPHIC_DIAGONAL_DOWN_LEFT ||
           kind == CELL_GRAPHIC_DIAGONAL_DOWN_RIGHT ||
           kind == CELL_GRAPHIC_DIAGONAL_CROSS;
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
    if (is_diagonal(graphic.kind)) {
        float pad = max(1.0, min(cell_size.x, cell_size.y) * 0.08);
        draw_position -= float2(pad);
        draw_size += float2(pad * 2.0);
    }

    float2 pixel_position = draw_position + (draw_size * transforms[vertex_id]);

    cell_graphic_rasterizer_data data;
    data.position = clip_position(uniforms, pixel_position);
    data.cell_position = cell_position;
    data.cell_size = cell_size;
    data.color = load_color(graphic.color);
    data.background_color = load_color(graphic.background_color);
    data.cursor_color = load_color(graphic.cursor_color);
    data.cursor_background_color =
        load_color(graphic.cursor_background_color);
    data.box_line_width = float(uniforms.box_line_width);
    data.kind = graphic.kind;
    data.flags = graphic.flags;
    return data;
}

fragment float4 background_fill(grid_rasterizer_data in [[stage_in]]) {
    return in.color;
}

fragment float4 line_fill(line_rasterizer_data in [[stage_in]]) {
    if (in.period < 0) { // undercurl - see line_render above
        float wavelength = -in.period;
        float amplitude = wavelength * 0.08;
        float wave_y =
            in.center_y + amplitude * sinpi(4.0 * in.position.x / wavelength);
        float dist = abs(in.position.y - wave_y);
        float alpha = (1.0 - smoothstep(0.75, 2.0, dist)) * in.color.a;
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

// Whether this fragment survives the block cursor's x-ray.
//
// A ligature spreads one mark across several cells, and its ink for the cursor
// cell usually belongs to a neighbor's glyph, so recoloring a cell cannot
// reveal what the cursor sits on. Instead the cursor rect shows only that
// cell's own character: every ordinary glyph is hidden inside it, and the
// character is drawn nowhere else. The rest of the ligature is untouched. The
// split is a clean cut rather than a blend, because the character carries the
// cursor's fade in its own color, exactly as a recolored cell does.
static float xray_coverage(constant uniform_data &uniforms,
                           float2 pixel_position, bool is_xray) {
    if (uniforms.cursor_xray == 0) {
        return is_xray ? 0.0 : 1.0;
    }

    float4 cursor_rect = cursor_pixel_rect(uniforms);
    bool inside = all(pixel_position >= cursor_rect.xy)
        && all(pixel_position < cursor_rect.xy + cursor_rect.zw);

    return inside == is_xray ? 1.0 : 0.0;
}

fragment float4 glyph_fill(glyph_rasterizer_data in [[stage_in]],
                           constant uniform_data &uniforms [[buffer(0)]],
                           texture2d_array<float> masks [[texture(0)]],
                           texture2d_array<float> colors [[texture(1)]]) {
    constexpr sampler texture_sampler(mag_filter::nearest,
                                      min_filter::nearest,
                                      address::clamp_to_zero,
                                      coord::pixel);

    float visible = xray_coverage(uniforms, in.pixel_position,
                                  (in.flags & GLYPH_FLAG_XRAY) != 0);

    if (in.atlas == 0) {
        float coverage = masks.sample(
            texture_sampler, in.texture_position, in.texture_index).r * visible;
        return float4(in.color.rgb * coverage, coverage);
    }

    // The color atlas is already premultiplied, gamma-encoded Display P3.
    return colors.sample(texture_sampler, in.texture_position,
                         in.texture_index) * visible;
}

static bool inside_rect(float2 point, float left, float top,
                        float right, float bottom) {
    return point.x >= left && point.x < right &&
           point.y >= top && point.y < bottom;
}

static float block_boundary(float length, uint32_t eighth) {
    return floor(length * float(eighth) / 8.0 + 0.5);
}

static uint32_t box_stroke(uint32_t kind, uint32_t shift) {
    return (kind >> shift) & CELL_GRAPHIC_STROKE_MASK;
}

// How far a stroke reaches at the cell centre, where it meets the two
// strokes crossing it. It stops at the near rail when the crossing pair
// forms an unbroken line that this stroke only abuts; otherwise it runs
// past the centre to the far rail matching the crossing weight.
static float box_junction_reach(uint32_t cross_a, uint32_t cross_b,
                                uint32_t parallel_a, uint32_t parallel_b,
                                float heavy_far, float double_far,
                                float light_far, float near) {
    if (cross_a == CELL_GRAPHIC_STROKE_HEAVY ||
        cross_b == CELL_GRAPHIC_STROKE_HEAVY) {
        return heavy_far;
    }
    // A crossing pair that is uneven, absent, or matched by this axis
    // cannot cap the stroke, so it reaches the far rail.
    if (cross_a != cross_b || parallel_a == parallel_b ||
        (cross_a == CELL_GRAPHIC_STROKE_NONE &&
         cross_b == CELL_GRAPHIC_STROKE_NONE)) {
        return cross_a == CELL_GRAPHIC_STROKE_DOUBLE ||
               cross_b == CELL_GRAPHIC_STROKE_DOUBLE
            ? double_far : light_far;
    }
    return near;
}

static bool box_segments_contain(float2 point, float2 size,
                                 float light_width, uint32_t kind) {
    uint32_t up = box_stroke(kind, CELL_GRAPHIC_BOX_UP_SHIFT);
    uint32_t right = box_stroke(kind, CELL_GRAPHIC_BOX_RIGHT_SHIFT);
    uint32_t down = box_stroke(kind, CELL_GRAPHIC_BOX_DOWN_SHIFT);
    uint32_t left = box_stroke(kind, CELL_GRAPHIC_BOX_LEFT_SHIFT);
    float heavy_width = light_width * 2.0;

    float h_light_top = floor((size.y - light_width) * 0.5);
    float h_light_bottom = h_light_top + light_width;
    float h_heavy_top = floor((size.y - heavy_width) * 0.5);
    float h_heavy_bottom = h_heavy_top + heavy_width;
    float h_double_top = h_light_top - light_width;
    float h_double_bottom = h_light_bottom + light_width;

    float v_light_left = floor((size.x - light_width) * 0.5);
    float v_light_right = v_light_left + light_width;
    float v_heavy_left = floor((size.x - heavy_width) * 0.5);
    float v_heavy_right = v_heavy_left + heavy_width;
    float v_double_left = v_light_left - light_width;
    float v_double_right = v_light_right + light_width;

    float up_bottom = box_junction_reach(left, right, up, down,
                                         h_heavy_bottom, h_double_bottom,
                                         h_light_bottom, h_light_top);
    float down_top = box_junction_reach(left, right, up, down,
                                        h_heavy_top, h_double_top,
                                        h_light_top, h_light_bottom);
    float left_right = box_junction_reach(up, down, left, right,
                                          v_heavy_right, v_double_right,
                                          v_light_right, v_light_left);
    float right_left = box_junction_reach(up, down, left, right,
                                          v_heavy_left, v_double_left,
                                          v_light_left, v_light_right);

    if (up == CELL_GRAPHIC_STROKE_LIGHT || up == CELL_GRAPHIC_STROKE_HEAVY) {
        bool heavy = up == CELL_GRAPHIC_STROKE_HEAVY;
        if (inside_rect(point, heavy ? v_heavy_left : v_light_left, 0,
                        heavy ? v_heavy_right : v_light_right, up_bottom)) {
            return true;
        }
    }
    if (up == CELL_GRAPHIC_STROKE_DOUBLE) {
        float left_bottom = left == CELL_GRAPHIC_STROKE_DOUBLE
            ? h_light_top : up_bottom;
        float right_bottom = right == CELL_GRAPHIC_STROKE_DOUBLE
            ? h_light_top : up_bottom;
        if (inside_rect(point, v_double_left, 0, v_light_left, left_bottom) ||
            inside_rect(point, v_light_right, 0, v_double_right,
                        right_bottom)) {
            return true;
        }
    }

    if (right == CELL_GRAPHIC_STROKE_LIGHT ||
        right == CELL_GRAPHIC_STROKE_HEAVY) {
        bool heavy = right == CELL_GRAPHIC_STROKE_HEAVY;
        if (inside_rect(point, right_left, heavy ? h_heavy_top : h_light_top,
                        size.x, heavy ? h_heavy_bottom : h_light_bottom)) {
            return true;
        }
    }
    if (right == CELL_GRAPHIC_STROKE_DOUBLE) {
        float top_left = up == CELL_GRAPHIC_STROKE_DOUBLE
            ? v_light_right : right_left;
        float bottom_left = down == CELL_GRAPHIC_STROKE_DOUBLE
            ? v_light_right : right_left;
        if (inside_rect(point, top_left, h_double_top, size.x, h_light_top) ||
            inside_rect(point, bottom_left, h_light_bottom, size.x,
                        h_double_bottom)) {
            return true;
        }
    }

    if (down == CELL_GRAPHIC_STROKE_LIGHT ||
        down == CELL_GRAPHIC_STROKE_HEAVY) {
        bool heavy = down == CELL_GRAPHIC_STROKE_HEAVY;
        if (inside_rect(point, heavy ? v_heavy_left : v_light_left, down_top,
                        heavy ? v_heavy_right : v_light_right, size.y)) {
            return true;
        }
    }
    if (down == CELL_GRAPHIC_STROKE_DOUBLE) {
        float left_top = left == CELL_GRAPHIC_STROKE_DOUBLE
            ? h_light_bottom : down_top;
        float right_top = right == CELL_GRAPHIC_STROKE_DOUBLE
            ? h_light_bottom : down_top;
        if (inside_rect(point, v_double_left, left_top, v_light_left, size.y) ||
            inside_rect(point, v_light_right, right_top, v_double_right,
                        size.y)) {
            return true;
        }
    }

    if (left == CELL_GRAPHIC_STROKE_LIGHT ||
        left == CELL_GRAPHIC_STROKE_HEAVY) {
        bool heavy = left == CELL_GRAPHIC_STROKE_HEAVY;
        if (inside_rect(point, 0, heavy ? h_heavy_top : h_light_top,
                        left_right, heavy ? h_heavy_bottom : h_light_bottom)) {
            return true;
        }
    }
    if (left == CELL_GRAPHIC_STROKE_DOUBLE) {
        float top_right = up == CELL_GRAPHIC_STROKE_DOUBLE
            ? v_light_left : left_right;
        float bottom_right = down == CELL_GRAPHIC_STROKE_DOUBLE
            ? v_light_left : left_right;
        if (inside_rect(point, 0, h_double_top, top_right, h_light_top) ||
            inside_rect(point, 0, h_light_bottom, bottom_right,
                        h_double_bottom)) {
            return true;
        }
    }

    return false;
}

// Distance to an axis-aligned segment. `across` is the point's offset
// from the segment's constant axis; `along` is its coordinate on the
// varying axis, which the segment spans between `a` and `b`.
static float axis_segment_distance(float across, float along,
                                   float a, float b) {
    float outside = along - clamp(along, min(a, b), max(a, b));
    return length(float2(across, outside));
}

static float arc_distance(float2 point, float2 size, float line_width,
                          uint32_t corner) {
    float2 middle = floor((size - line_width) * 0.5) + line_width * 0.5;
    float radius = min(size.x, size.y) * 0.5;
    float x_sign = corner == CELL_GRAPHIC_ARC_DOWN_LEFT ||
                   corner == CELL_GRAPHIC_ARC_UP_LEFT ? -1.0 : 1.0;
    float y_sign = corner == CELL_GRAPHIC_ARC_UP_LEFT ||
                   corner == CELL_GRAPHIC_ARC_UP_RIGHT ? -1.0 : 1.0;
    float2 circle_center = middle + float2(x_sign, y_sign) * radius;

    // Both arms are axis-aligned: one runs down the cell's vertical
    // centre to the arc, the other along its horizontal centre.
    float vertical_join = middle.y + y_sign * radius;
    float vertical_edge = y_sign < 0 ? 0.0 : size.y;
    float horizontal_join = middle.x + x_sign * radius;
    float horizontal_edge = x_sign < 0 ? 0.0 : size.x;
    float distance = min(axis_segment_distance(point.x - middle.x, point.y,
                                               vertical_edge, vertical_join),
                         axis_segment_distance(point.y - middle.y, point.x,
                                               horizontal_join,
                                               horizontal_edge));

    bool inside_x = x_sign < 0 ? point.x >= circle_center.x
                               : point.x <= circle_center.x;
    bool inside_y = y_sign < 0 ? point.y >= circle_center.y
                               : point.y <= circle_center.y;
    if (inside_x && inside_y) {
        distance = min(distance,
                       abs(length(point - circle_center) - radius));
    }
    return distance;
}

fragment float4 cell_graphic_fill(
        cell_graphic_rasterizer_data in [[stage_in]],
        constant uniform_data &uniforms [[buffer(0)]]) {
    float4 cursor_rect = cursor_pixel_rect(uniforms);
    bool recolor = (in.flags & CELL_GRAPHIC_FLAG_CURSOR) != 0 &&
        all(in.position.xy >= cursor_rect.xy) &&
        all(in.position.xy < cursor_rect.xy + cursor_rect.zw);
    float4 color = recolor ? in.cursor_color : in.color;
    float4 background_color = recolor
        ? in.cursor_background_color : in.background_color;

    if (in.kind == CELL_GRAPHIC_FULL_BLOCK) {
        return float4(color.rgb, 1.0);
    }

    if (in.kind == CELL_GRAPHIC_DARK_SHADE ||
        in.kind == CELL_GRAPHIC_MEDIUM_SHADE ||
        in.kind == CELL_GRAPHIC_LIGHT_SHADE) {
        float coverage = in.kind == CELL_GRAPHIC_DARK_SHADE ? 0.57
                       : in.kind == CELL_GRAPHIC_MEDIUM_SHADE ? 0.26 : 0.08;
        return float4(mix(background_color.rgb, color.rgb, coverage), 1.0);
    }

    float2 local = in.position.xy - in.cell_position;
    float width = in.cell_size.x;
    float height = in.cell_size.y;
    float light_width = in.box_line_width;
    uint32_t family = in.kind & CELL_GRAPHIC_FAMILY_MASK;

    if (family == CELL_GRAPHIC_BLOCK_RECT) {
        float left = block_boundary(
            width, (in.kind >> CELL_GRAPHIC_BLOCK_LEFT_SHIFT)
                   & CELL_GRAPHIC_BLOCK_BOUNDARY_MASK);
        float top = block_boundary(
            height, (in.kind >> CELL_GRAPHIC_BLOCK_TOP_SHIFT)
                    & CELL_GRAPHIC_BLOCK_BOUNDARY_MASK);
        float right = block_boundary(
            width, (in.kind >> CELL_GRAPHIC_BLOCK_RIGHT_SHIFT)
                   & CELL_GRAPHIC_BLOCK_BOUNDARY_MASK);
        float bottom = block_boundary(
            height, (in.kind >> CELL_GRAPHIC_BLOCK_BOTTOM_SHIFT)
                    & CELL_GRAPHIC_BLOCK_BOUNDARY_MASK);
        if (!inside_rect(local, left, top, right, bottom)) {
            discard_fragment();
        }
        return float4(color.rgb, 1.0);
    }

    if (family == CELL_GRAPHIC_BLOCK_QUADRANTS) {
        float middle_x = block_boundary(width, 4u);
        float middle_y = block_boundary(height, 4u);
        uint32_t quadrant = local.y < middle_y ? 0u : 2u;
        quadrant += local.x < middle_x ? 0u : 1u;
        if ((in.kind & (1u << quadrant)) == 0) {
            discard_fragment();
        }
        return float4(color.rgb, 1.0);
    }

    if (family == CELL_GRAPHIC_BOX_SEGMENTS) {
        if (!box_segments_contain(local, in.cell_size, light_width, in.kind)) {
            discard_fragment();
        }
        return float4(color.rgb, 1.0);
    }

    if (family == CELL_GRAPHIC_BOX_DASHED) {
        bool vertical = (in.kind & CELL_GRAPHIC_DASH_VERTICAL) != 0;
        bool heavy = (in.kind & CELL_GRAPHIC_DASH_HEAVY) != 0;
        uint32_t count = 2 +
            ((in.kind >> CELL_GRAPHIC_DASH_COUNT_SHIFT) & 3u);
        float thickness = heavy ? light_width * 2.0 : light_width;
        float cross_size = vertical ? width : height;
        float cross = vertical ? local.x : local.y;
        float cross_start = floor((cross_size - thickness) * 0.5);
        float along_size = vertical ? height : width;
        float along = vertical ? local.y : local.x;
        float period = along_size / float(count);
        float half_gap = period * 0.175;
        float phase = fmod(along, period);
        if (cross < cross_start || cross >= cross_start + thickness ||
            phase < half_gap || phase >= period - half_gap) {
            discard_fragment();
        }
        return float4(color.rgb, 1.0);
    }

    float distance = 0.0;
    if (family == CELL_GRAPHIC_BOX_ARC) {
        distance = arc_distance(local, in.cell_size, light_width,
                                in.kind & ~CELL_GRAPHIC_FAMILY_MASK);
    } else if (is_diagonal(in.kind)) {
        float inverse_length = 1.0 / length(in.cell_size);
        float down_left = abs(local.x * height + local.y * width -
                              width * height) * inverse_length;
        float down_right = abs(local.x * height - local.y * width) *
                           inverse_length;
        distance = in.kind == CELL_GRAPHIC_DIAGONAL_DOWN_LEFT ? down_left
                 : in.kind == CELL_GRAPHIC_DIAGONAL_DOWN_RIGHT ? down_right
                 : min(down_left, down_right);
    } else {
        discard_fragment();
    }

    float half_width = light_width * 0.5;
    float alpha = 1.0 - smoothstep(half_width - 0.5,
                                   half_width + 0.5, distance);
    if (alpha <= 0.0) discard_fragment();
    return float4(color.rgb, alpha);
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
