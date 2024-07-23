#version 450

layout(binding = 1) uniform sampler2D tex_atlas;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(tex_atlas, in_uv) * in_color;
    if (out_color.a < 0.01) discard;
}
