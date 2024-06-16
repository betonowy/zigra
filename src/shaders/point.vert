#version 450

#include <gen/pc/BasicPushConstant.glsl>

struct PointDataPacked {
    vec3 point;
    uvec2 color_packed_f16x4;
};

struct PointData {
    vec3 point;
    vec4 color;
};

layout(std430, set = 0, binding = 0) readonly buffer ObjectBuffer {
	PointDataPacked objects[];
} draw_buffer;

layout(location = 0) out vec4 out_color;

PointData getPointData(uint i) {
    PointDataPacked packed = draw_buffer.objects[i];
    PointData unpacked;

    unpacked.point.xyz = packed.point;
    unpacked.color.rg = unpackHalf2x16(packed.color_packed_f16x4[0]);
    unpacked.color.ba = unpackHalf2x16(packed.color_packed_f16x4[1]);

    return unpacked;
}

void main() {
    PointData data = getPointData(gl_VertexIndex);
    out_color = data.color;
    gl_Position = vec4((round(data.point.xy - pc.camera_pos)) / (pc.target_size * 0.5), data.point.z, 1.0);
    gl_PointSize = 1.0;
}
