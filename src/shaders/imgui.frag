#version 450

#include "color.glsl"

layout(location = 0) in vec2 inUV;

layout(binding = 0) uniform sampler2D inTex;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(inTex, inUV);
    outColor.rgb = srgb_to_rgb(outColor.rgb);
}
