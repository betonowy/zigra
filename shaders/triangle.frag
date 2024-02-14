#version 450

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 texCoord;

// layout(binding = 1) uniform sampler2D texSampler;

layout(location = 0) out vec4 outColor;

// layout(push_constant, std430) uniform pc {
//     vec4 color;
// };

void main() {
    outColor = vec4(fragColor, 1.0);
}
