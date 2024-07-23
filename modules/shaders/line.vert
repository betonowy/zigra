#version 450

#include <gen/pc/BasicPushConstant.glsl>

struct LineDataPacked {
    vec2 points[2];
    uvec2 color_packed_f16x4;
    float depth;
    uint alpha_gradient_packed_f16x2;
};

struct LineData {
    vec3 point;
    vec4 color;
};

layout(std430, set = 0, binding = 0) readonly buffer ObjectBuffer {
	LineDataPacked objects[];
} draw_buffer;

layout(location = 0) out vec4 out_color;

LineData getLineData(uint i, uint v) {
    LineDataPacked packed = draw_buffer.objects[i];
    LineData unpacked;

    unpacked.point.xy = packed.points[v];
    unpacked.color.rg = unpackHalf2x16(packed.color_packed_f16x4[0]);
    unpacked.color.ba = unpackHalf2x16(packed.color_packed_f16x4[1]);
    unpacked.point.z = packed.depth;
    unpacked.color.a *= unpackHalf2x16(packed.alpha_gradient_packed_f16x2)[v];

    return unpacked;
}

void main() {
    LineData data = getLineData(gl_InstanceIndex, gl_VertexIndex);
    out_color = data.color;
    gl_Position = vec4((round(data.point.xy - pc.camera_pos)) / (pc.target_size * 0.5), data.point.z, 1.0);
}
