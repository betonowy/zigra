#version 450

#include <gen/pc/TextPushConstant.glsl>

struct TextDataPacked {
    vec3 offset;
    uvec2 color_packed_f16x4;
    uint char;
};

struct TextData {
    vec3 offset;
    vec4 color;
    uint char;
};

layout(std430, set = 0, binding = 0) readonly buffer ObjectBuffer {
	TextDataPacked objects[];
} draw_buffer;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;

TextData getTextData(uint i) {
    TextDataPacked packed = draw_buffer.objects[i];
    TextData unpacked;

    unpacked.offset.xyz = packed.offset;
    unpacked.color.xy = unpackHalf2x16(packed.color_packed_f16x4[0]);
    unpacked.color.zw = unpackHalf2x16(packed.color_packed_f16x4[1]);
    unpacked.char = packed.char;

    return unpacked;
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
    TextData data = getTextData(gl_InstanceIndex);

    out_color = data.color;

    vec2 pos = init_pos[gl_VertexIndex] * pc.base_stride;

    out_uv = pos + vec2((data.char % pc.stride_len) * pc.base_stride, (data.char / pc.stride_len) * pc.base_stride ) + vec2(pc.font_sheet_base);
    out_uv += uv_correction[gl_VertexIndex];
    out_uv /= pc.atlas_size;

    data.offset += vec3(pos, 0.0);

    gl_Position = vec4((round(data.offset.xy - pc.camera_pos)) / (pc.target_size * 0.5), data.offset.z, 1.0);
    gl_PointSize = 1.0;
}
