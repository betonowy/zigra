#version 450

#include <ubo.glsl>

layout(binding = 0, std140) uniform UBO_DEF ubo;
layout(binding = 1) uniform sampler2D tex_im;
layout(binding = 2) uniform sampler2D tex_dui;

layout(location = 0) out vec4 out_color;

int targetScaling() {
    uvec2 scaling_u2 = ubo.window_size / ubo.target_size;
    return int(min(scaling_u2.x, scaling_u2.y));
}

ivec2 targetOffset(int scaling) {
    return ivec2(ubo.window_size - scaling * ubo.target_size) >> 1;
}

void main() {
    ivec2 coord = ivec2(gl_FragCoord.xy);

    int target_scaling = targetScaling();
    ivec2 target_offset = targetOffset(target_scaling);

    out_color = texelFetch(tex_im, (coord - target_offset) / target_scaling, 0);

    vec4 dui_color = texelFetch(tex_dui, coord, 0);

    out_color = mix(out_color, dui_color, dui_color.a * 0.75);
}
