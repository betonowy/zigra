#version 450

#include <gen/pc/BasicPushConstant.glsl>

struct LandscapeData {
    ivec2 offset;
    ivec2 size;
    int descriptor;
    float depth;
    uvec2 _padding2;
};

layout(std430, set = 0, binding = 0) readonly buffer ObjectBuffer {
	LandscapeData objects[];
} draw_buffer;

layout(location = 0) flat out int out_descriptor;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec2 out_pos_global;

LandscapeData getLandscapeData(uint i) {
    return draw_buffer.objects[i];
}

vec2 init_pos[4] = vec2[](
    vec2(0, 1),
    vec2(1, 1),
    vec2(0, 0),
    vec2(1, 0)
);

const float uv_epsilon = 1.0 / 128.0;

vec2 uv_correction[4] = vec2[](
    vec2( uv_epsilon, -uv_epsilon),
    vec2(-uv_epsilon, -uv_epsilon),
    vec2( uv_epsilon,  uv_epsilon),
    vec2(-uv_epsilon,  uv_epsilon)
);

void main() {
    LandscapeData data = getLandscapeData(gl_InstanceIndex);

    vec2 pos = init_pos[gl_VertexIndex];

    pos *= data.size;

    out_pos_global = pos + data.offset;

    pos = round(out_pos_global - pc.camera_pos);
    pos /= pc.target_size * 0.5;

    out_uv = init_pos[gl_VertexIndex];
    out_descriptor = data.descriptor;

    gl_Position = vec4(pos, data.depth, 1.0);
}
