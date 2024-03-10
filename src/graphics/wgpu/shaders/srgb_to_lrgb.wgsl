@group(0) @binding(0) var u_texture: texture_2d<f32>;
@group(0) @binding(1) var u_sampler: sampler;

struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var positions = array<vec2<f32>, 4>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(1.0, -1.0),
        vec2<f32>(-1.0, 1.0),
        vec2<f32>(1.0, 1.0),
    );

    var uvs = array<vec2<f32>, 4>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
    );

    var indices = array<u32, 6>(0u, 1u, 2u, 1u, 3u, 2u);
    let index = indices[vertex_index];

    return VertexOutput(vec4<f32>(positions[index], 0.0, 1.0), uvs[index]);
}

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    var color: vec4<f32> = textureSample(u_texture, u_sampler, uv);
    color = vec4<f32>(lrgb_from_srgb(color.rgb), color.a);
    return color;
}

fn inv_gamma(c: f32) -> f32 {
    if c <= 0.04045 {
        return c / 12.92;
    } else {
        return pow((c + 0.055) / 1.055, 2.4);
    }
}

fn lrgb_from_srgb(srgb: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        inv_gamma(srgb.r),
        inv_gamma(srgb.g),
        inv_gamma(srgb.b),
    );
}

fn lrgb_from_hsv(hsv: vec3<f32>) -> vec3<f32> {
    return lrgb_from_srgb(srgb_from_hsv(hsv));
}

fn gamma(u: f32) -> f32 {
    if u <= 0.0031308 {
        return 12.92 * u;
    } else {
        return (1.055 * pow(u, 1.0 / 2.4)) - 0.055;
    }
}

fn srgb_from_lrgb(lrgb: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(gamma(lrgb.r), gamma(lrgb.g), gamma(lrgb.b));
}

fn hsv_f(hsv: vec3<f32>, n: f32) -> f32 {
    let k = (n + hsv.x / radians(60.0)) % 6.0;
    return hsv.z - hsv.z * hsv.y * max(0.0, min(k, min(4.0 - k, 1.0)));
}

fn srgb_from_hsv(hsv: vec3<f32>) -> vec3<f32> {
    let tau = radians(360.0);
    let hsv_mod = vec3<f32>(hsv.x % tau, hsv.yz);
    return vec3<f32>(hsv_f(hsv_mod, 5.0), hsv_f(hsv_mod, 3.0), hsv_f(hsv_mod, 1.0));
}
