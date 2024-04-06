#version 450

#include <gen/landscape/Cells.glsl>

#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 3) uniform usampler2D tex_landscape[];

layout(location = 0) flat in uint in_descriptor;
layout(location = 1) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

vec4 getColor(uint code) {

    // bkg dependent rendering
    switch (code) {
        case CellType_air: return vec4(0);
    }

    // bkg independent rendering
    switch (code | 0x80) {
        case CellType_bkg: return vec4(0.025, 0.0125, 0.00625, 1.0);
        case CellType_soil: return vec4(0.1, 0.05, 0.025, 1.0);
        case CellType_gold: return vec4(0.5, 0.25, 0.0, 1.0);
        case CellType_rock: return vec4(0.25, 0.25, 0.25, 1.0);
        case CellType_water: return vec4(0.0125, 0.025, 0.5, 1.0);
        case CellType_acid: return vec4(0.0125, 0.5, 0.025, 1.0);
        case CellType_sand: return vec4(0.5, 0.45, 0.25, 1.0);
    }

    return vec4(1, 0, 1, 1);
}

void main() {
    uint code = texture(tex_landscape[in_descriptor], in_uv).r;
    out_color = getColor(code);
}
