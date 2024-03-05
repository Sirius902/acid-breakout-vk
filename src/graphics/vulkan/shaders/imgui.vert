#version 450

layout(location = 0) out vec2 outUV;

const vec2 positions[4] = vec2[](
    vec2(-1.0, -1.0),
    vec2(-1.0, 1.0),
    vec2(1.0, -1.0),
    vec2(1.0, 1.0)
);

const vec2 uvs[4] = vec2[](
    vec2(0.0, 0.0),
    vec2(0.0, 1.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0)
);

const uint indices[6] = uint[](0, 1, 2, 1, 3, 2);

void main() {
    const uint vertexIndex = indices[gl_VertexIndex];
    gl_Position = vec4(positions[vertexIndex], 0.0, 1.0);
    outUV = uvs[vertexIndex];
}
