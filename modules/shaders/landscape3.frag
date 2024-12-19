#version 450

#include <gen/landscape/Cells.glsl>

#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 4) uniform sampler2D tex_landscape3;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec2 in_pos_global;
layout(location = 2) in vec2 in_uv_pixel_size;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(tex_landscape3, in_uv);
    if (out_color.a < 0.5) discard;
}
