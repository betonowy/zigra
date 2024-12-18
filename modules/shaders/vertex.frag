#version 450

layout(binding = 1) uniform sampler2D tex_atlas;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in float in_alpha_factor;

layout(location = 0) out vec4 out_color;

const vec4 identity_v4 = vec4(1.0, 1.0, 1.0, 1.0);
const float alpha_discard_threshold = 0.5;

void main() {
    out_color = (any(isnan(in_uv)) ? identity_v4 : texture(tex_atlas, in_uv)) * in_color;
    if (out_color.a < alpha_discard_threshold) discard;
    out_color.a *= in_alpha_factor;
}
