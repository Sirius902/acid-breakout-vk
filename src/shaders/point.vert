#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec4 inColor;
layout(location = 2) in uint inShading;

layout(location = 0) out vec4 fragColor;
layout(location = 1) out uint shading;

layout(push_constant) uniform PushConstants {
    mat4 view;
    vec2 aspect;
    vec2 viewport_size;
    float time;
} pc;

void main() {
#ifndef IS_LINE
    gl_PointSize = 1.0;
#endif

    gl_Position = pc.view * vec4(inPosition, 0.0, 1.0);
    fragColor = inColor;
    shading = inShading;
}
