#version 450

vec2 positions[3] = vec2[](
    vec2(-4.0, -2.0),
    vec2(0.0, 4.0),
    vec2(4.0, -2.0)
);

layout(location = 0) out vec2 texCoord;

void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0.5, 1.0);
    texCoord = (positions[gl_VertexIndex] + 1.0) * 0.5;
}
