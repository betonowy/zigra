#version 450

#include <gen/landscape/Cells.glsl>

#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 3) uniform usampler2D tex_landscape[];
layout(binding = 4) uniform usampler2D tex_landscape2;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec2 in_pos_global;

layout(location = 0) out vec4 out_color;

float rand(vec2 n)
{
	return fract(sin(dot(n, vec2(12.9898, 4.1414))) * 43758.5453);
}

float noise(vec2 p)
{
	vec2 ip = floor(p);
	vec2 u = fract(p);
	u = u*u*(3.0-2.0*u);

	float res = mix(
		mix(rand(ip),rand(ip+vec2(1.0,0.0)),u.x),
		mix(rand(ip+vec2(0.0,1.0)),rand(ip+vec2(1.0,1.0)),u.x),u.y);
	return res*res;
}

vec4 greyNoise(vec2 p, float intensity, float size)
{
    vec4 value = vec4(vec3(noise(p * size)), 1.0);
    return mix(vec4(1.0), value, intensity);
}

vec4 getColor(uint code) {
    uint type = code & 0xff;

    // bkg dependent rendering
    switch (type) {
        case CellType_air: return vec4(0);
    }

    uint property_1 = code >> 8 & 0xf;
    uint property_2 = code >> 12 & 0xf;

    // bkg independent rendering
    switch (type | 0x80) {
        case CellType_bkg: return vec4(0.025, 0.0125, 0.00625, 1.0) * greyNoise(in_pos_global, 0.3, 0.5);
        case CellType_soil: return vec4(0.1, 0.05, 0.025, 1.0) * greyNoise(in_pos_global, 0.3, 1.0);
        case CellType_gold: return vec4(0.5, 0.25, 0.0, 1.0) * greyNoise(in_pos_global, 0.1, 0.3);
        case CellType_rock: return vec4(0.25, 0.25, 0.25, 1.0) * greyNoise(in_pos_global, 0.1, 0.2);
        case CellType_water: return vec4(0.0125, 0.025, 0.5, 1.0) * greyNoise(in_pos_global, 0.1, 2.0);
        case CellType_acid: return vec4(0.0125, 0.5, 0.025, 1.0);
        case CellType_sand: return vec4(0.5, 0.45, 0.25, 1.0) * greyNoise(in_pos_global, 0.3, 4.13);
    }

    return vec4(1, 0, 1, 1);
}

void main() {
    // uint code = texture(tex_landscape[in_descriptor], in_uv).r;
    uint code = texture(tex_landscape2, in_uv).r;
    out_color = getColor(code);

    if (out_color.a < 0.1) discard;
}
