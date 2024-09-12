#version 450

layout(binding = 1) uniform sampler2D tex_atlas;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in float in_texture_blend;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = mix(vec4(1.0), texture(tex_atlas, in_uv), in_texture_blend) * in_color;
    if (out_color.a < 0.5) discard;
}
