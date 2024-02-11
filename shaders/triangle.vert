#version 450

// layout(location = 0) in vec3 inPosition;
// layout(location = 1) in vec3 inColor;

struct ObjectData {
    vec3 pos;
    vec3 col;
};

layout(std430, set = 0, binding = 1) readonly buffer ObjectBuffer{
	ObjectData objects[];
} objectBuffer;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 texCoord;

layout(push_constant, std430) uniform pc {
    vec3 offset;
};

vec2 positions[3] = vec2[](
    vec2(0.0, -0.5),
    vec2(0.5, 0.5),
    vec2(-0.5, 0.5)
);

vec3 colors[3] = vec3[](
    vec3(1.0, 0.0, 0.0),
    vec3(0.0, 1.0, 0.0),
    vec3(0.0, 0.0, 1.0)
);

void main() {
    gl_Position = vec4(objectBuffer.objects[gl_VertexIndex].pos + offset, 1.0);
    fragColor = objectBuffer.objects[gl_VertexIndex].col;
    texCoord = positions[gl_VertexIndex];
}
