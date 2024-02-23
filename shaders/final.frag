#version 450

layout(binding = 2) uniform sampler2D tex_color;
layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(tex_color, in_uv);
}
