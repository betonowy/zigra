#version 450
#extension GL_EXT_nonuniform_qualifier : require

#include <ubo.glsl>

layout(binding = 0, std140) uniform UBO_DEF ubo;
layout(binding = 1) uniform sampler2DArray tex_atlas[];

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) flat in uvec2 in_tex_ref;

layout(location = 0) out vec4 out_color;

const vec4 identity_v4 = vec4(1.0, 1.0, 1.0, 1.0);

void main() {
    out_color = (
        any(isnan(in_uv))
        ? identity_v4
        : texture(
            tex_atlas[in_tex_ref[0]],
            vec3(
                in_uv / textureSize(tex_atlas[in_tex_ref[0]], 0).xy,
                in_tex_ref[1]
            )
        )
    ) * in_color;

    if (out_color.a < 0.5) discard;

    // out_color = in_color;
    out_color.a = 1.0;
}
