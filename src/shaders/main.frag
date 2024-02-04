#version 450

#define SHADING_COLOR 0
#define SHADING_RAINBOW 1
#define SHADING_RAINBOW_SCROLL 2

#include "color.glsl"

layout(location = 0) in vec4 fragColor;
layout(location = 1) flat in uint shading;

layout(location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstants {
    mat4 view;
    vec2 viewport_size;
    float time;
} pc;

void main() {
    vec2 pos = gl_FragCoord.xy / pc.viewport_size;

    switch (shading) {
        case SHADING_COLOR:
            outColor = fragColor;
            break;
        case SHADING_RAINBOW:
            outColor = vec4(lrgb_from_hsv(vec3(pos.x * radians(360.0), 1.0, 1.0)), fragColor.a);
            break;
        case SHADING_RAINBOW_SCROLL:
            outColor = vec4(lrgb_from_hsv(vec3(pos.x * radians(360.0) + pc.time, 1.0, 1.0)), fragColor.a);
            break;
    }
}
