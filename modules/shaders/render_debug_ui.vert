#version 450

#include <ubo.glsl>

layout(binding = 0, std140) uniform UBO_DEF ubo;

struct VertexDataPacked {
    vec2 pos;
    uvec2 col_packed_f16x4;
    vec2 uv;
    uvec2 tex_ref;
};

struct VertexData {
    vec2 pos;
    vec4 col;
    vec2 uv;
    uvec2 tex_ref;
};

layout(std430, binding = 2) readonly buffer ObjectBuffer {
	VertexDataPacked objects[];
} draw_buffer;

layout(location = 0) out vec4 out_col;
layout(location = 1) out vec2 out_uv;
layout(location = 2) flat out uvec2 out_tex_ref;

VertexData getVertexData(uint i) {
    VertexDataPacked packed = draw_buffer.objects[i];
    VertexData unpacked;

    unpacked.pos.xy = packed.pos;
    unpacked.col.rg = unpackHalf2x16(packed.col_packed_f16x4[0]);
    unpacked.col.ba = unpackHalf2x16(packed.col_packed_f16x4[1]);
    unpacked.uv.xy = packed.uv;
    unpacked.tex_ref = packed.tex_ref;

    return unpacked;
}

void main() {
    VertexData data = getVertexData(gl_VertexIndex);

    out_uv = data.uv;
    out_col = data.col;
    out_tex_ref = data.tex_ref;

    gl_Position = vec4(
        (data.pos / vec2(ubo.window_size)) * 2.0 - 1.0,
        vec2(0.5, 1.0)
    );
}
