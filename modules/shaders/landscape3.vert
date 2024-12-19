#version 450

#include <gen/pc/LandscapePushConstant.glsl>

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec2 out_pos_global;
layout(location = 2) out vec2 out_uv_pixel_size;

vec4 triangle_pos[3] = vec4[](
    vec4(-2, -2, 0.95, 1.0),
    vec4(2, -2, 0.95, 1.0),
    vec4(0, 4, 0.95, 1.0)
);

void main() {
    vec4 pos = triangle_pos[gl_VertexIndex];

    gl_Position = pos;

    float vertical_factor = pc.target_size.y / float(pc.buffer_size.y);
    float horizontal_factor = pc.target_size.x / float(pc.buffer_size.x);

    vec2 factor = vec2(horizontal_factor, vertical_factor);

    out_pos_global = pc.camera_pos + pos.xy * pc.target_size * 0.5;
    out_uv = (pos.xy * factor + 1.0) * 0.5;
    out_uv_pixel_size = 0.5 / pc.target_size;
}
