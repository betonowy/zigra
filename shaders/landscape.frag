#version 450

#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 3) uniform usampler2D tex_landscape[];

layout(location = 0) flat in uint in_descriptor;
layout(location = 1) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(tex_landscape[in_descriptor], in_uv) / 500.0;

    if (abs(in_uv.x - 0.5) > 0.49 || abs(in_uv.y - 0.5) > 0.49) {
        out_color = vec4(0.1, 0.2, 0.05, 1.0);
    }
}
