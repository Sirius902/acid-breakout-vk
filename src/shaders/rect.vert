#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;

layout(location = 2) in mat4 inModel;
layout(location = 6) in vec4 inColor;
layout(location = 7) in uint inShading;

layout(location = 0) out vec4 fragColor;
layout(location = 1) out uint shading;
layout(location = 2) out vec2 uv;

layout(push_constant) uniform PushConstants {
    mat4 view;
    vec2 aspect;
    vec2 viewport_size;
    float time;
} pc;

void main() {
    gl_Position = pc.view * inModel * vec4(inPosition, 0.0, 1.0);
    fragColor = inColor;
    shading = inShading;
    uv = inUV;
}
