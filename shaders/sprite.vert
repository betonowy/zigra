#version 450

#include <basic_push_constant.glsl>

struct SpriteDataPacked {
    vec2 offset;
    uvec2 color_packed_f16x4;
    uint pivot_packed_f16x2;
    uint uv_ul_packed_u16x2;
    uint uv_sz_packed_u16x2;
    uint depth_rot_packed_unorm16_snorm16;
};

struct SpriteData {
    vec2 offset;
    vec4 color;
    vec2 pivot;
    uvec2 uv_ul;
    uvec2 uv_sz;
    float depth;
    float rot;
};

layout(std430, set = 0, binding = 0) readonly buffer ObjectBuffer{
	SpriteDataPacked objects[];
} draw_buffer;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;

SpriteData getSpriteData(uint i) {
    SpriteDataPacked packed = draw_buffer.objects[i];
    SpriteData unpacked;

    unpacked.offset   = packed.offset;
    unpacked.color.rg = unpackHalf2x16(packed.color_packed_f16x4[0]);
    unpacked.color.ba = unpackHalf2x16(packed.color_packed_f16x4[1]);
    unpacked.pivot    = unpackHalf2x16(packed.pivot_packed_f16x2);
    unpacked.uv_ul.x  = (packed.uv_ul_packed_u16x2 >> 0x00) & 0xffff;
    unpacked.uv_ul.y  = (packed.uv_ul_packed_u16x2 >> 0x10) & 0xffff;
    unpacked.uv_sz.x  = (packed.uv_sz_packed_u16x2 >> 0x00) & 0xffff;
    unpacked.uv_sz.y  = (packed.uv_sz_packed_u16x2 >> 0x10) & 0xffff;

    vec2 depth_rot_snorm = unpackSnorm2x16(packed.depth_rot_packed_unorm16_snorm16);
    vec2 depth_rot_unorm = unpackUnorm2x16(packed.depth_rot_packed_unorm16_snorm16);

    unpacked.depth = depth_rot_unorm[0] * 1.0;
    unpacked.rot   = depth_rot_snorm[1] * 3.14159265359;

    return unpacked;
}

vec2 init_pos[4] = vec2[](
    vec2(-1,  1),
    vec2( 1,  1),
    vec2(-1, -1),
    vec2( 1, -1)
);

vec2 init_uv[4] = vec2[](
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
    SpriteData data = getSpriteData(gl_InstanceIndex);

    vec2 pos = init_pos[gl_VertexIndex] - data.pivot;

    float sin_rot = sin(data.rot);
    float cos_rot = cos(data.rot);

    pos *= data.uv_sz * 0.5;

    pos = vec2(pos.x * cos_rot - pos.y * sin_rot,
               pos.y * cos_rot + pos.x * sin_rot);

    pos = round(pos + data.offset - push.camera_pos);
    pos /= push.target_size * 0.5;

    out_color = data.color;

    out_uv = init_uv[gl_VertexIndex] * data.uv_sz + data.uv_ul;
    out_uv += uv_correction[gl_VertexIndex];
    out_uv /= push.atlas_size;

    gl_Position = vec4(pos, data.depth, 1.0);
}
