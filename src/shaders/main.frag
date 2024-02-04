#version 450

#define SHADING_COLOR 0
#define SHADING_RAINBOW 1
#define SHADING_RAINBOW_SCROLL 2

layout(location = 0) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstants {
    mat4 view;
    vec2 viewport_size;
    float time;
    uint shading;
} pc;

vec3 hsv_to_rgb(vec3 in_hsv) {
    const float tau = radians(360.0);
    vec3 hsv = vec3(mod(in_hsv.x, tau), mod(in_hsv.y, tau), mod(in_hsv.z, tau));
    float chroma = hsv.y * hsv.z;
    float x = chroma * (1.0 - abs(mod(hsv.x / radians(60.0), 2.0) - 1.0));
    float m = hsv.z - chroma;

    float r, g, b;
    if (hsv.x >= 0.0 && hsv.x < radians(60.0)) {
        r = chroma;
        g = x;
        b = 0.0;
    } else if (hsv.x >= radians(60.0) && hsv.x < radians(120.0)) {
        r = x;
        g = chroma;
        b = 0.0;
    } else if (hsv.x >= radians(120.0) && hsv.x < radians(180.0)) {
        r = 0.0;
        g = chroma;
        b = x;
    } else if (hsv.x >= radians(180.0) && hsv.x < radians(240.0)) {
        r = 0.0;
        g = x;
        b = chroma;
    } else if (hsv.x >= radians(240.0) && hsv.x < radians(300.0)) {
        r = x;
        g = 0.0;
        b = chroma;
    } else if (hsv.x >= radians(300.0) && hsv.x < radians(360.0)) {
        r = chroma;
        g = 0.0;
        b = x;
    }

    return vec3(r + m, g + m, b + m);
}

float gamma(float u) {
    if (u <= 0.0031308) {
        return 12.92 * u;
    } else {
        return (1.055 * pow(u, 1.0 / 2.4)) - 0.055;
    }
}

vec3 rgb_to_srgb(vec3 c) {
    return vec3(gamma(c.r), gamma(c.g), gamma(c.b));
}

void main() {
    vec2 pos = gl_FragCoord.xy / pc.viewport_size;

    switch (pc.shading) {
        case SHADING_COLOR:
            outColor = fragColor;
            break;
        case SHADING_RAINBOW:
            outColor = vec4(rgb_to_srgb(hsv_to_rgb(vec3(pos.x * radians(360.0), 1.0, 1.0))), fragColor.a);
            break;
        case SHADING_RAINBOW_SCROLL:
            outColor = vec4(rgb_to_srgb(hsv_to_rgb(vec3(pos.x * radians(360.0) + pc.time, 1.0, 1.0))), fragColor.a);
            break;
    }
}
