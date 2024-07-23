#version 450

#include <gen/pc/BasicPushConstant.glsl>

struct VertexDataPacked {
    vec3 point;
    uvec2 color_packed_f16x4;
    vec2 uv;
};

struct VertexData {
    vec3 point;
    vec4 color;
    vec2 uv;
};

layout(std430, set = 0, binding = 0) readonly buffer ObjectBuffer {
	VertexDataPacked objects[];
} draw_buffer;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;

VertexData getVertexData(uint i) {
    VertexDataPacked packed = draw_buffer.objects[i];
    VertexData unpacked;

    unpacked.point.xyz = packed.point;
    unpacked.color.rg = unpackHalf2x16(packed.color_packed_f16x4[0]);
    unpacked.color.ba = unpackHalf2x16(packed.color_packed_f16x4[1]);
    unpacked.uv.xy = packed.uv;

    return unpacked;
}

void main() {
    VertexData data = getVertexData(gl_VertexIndex);

    out_uv = data.uv / pc.atlas_size;
    out_color = data.color;

    gl_Position = vec4((data.point.xy - pc.camera_pos) / (pc.target_size * 0.5), data.point.z, 1.0);
    gl_PointSize = 1.0;
}
