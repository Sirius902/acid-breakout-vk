@group(0) @binding(0) var<uniform> ubo: UniformBufferObject;

@group(1) @binding(0) var u_mask_texture: texture_2d<f32>;
@group(1) @binding(1) var u_mask_sampler: sampler;

struct UniformBufferObject {
    view: mat4x4<f32>,
    aspect: vec2<f32>,
    viewport_size: vec2<f32>,
    time: f32,
    color_correction: u32,
}

struct VertexInput {
    @location(0) pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
}

struct InstanceInput {
    @location(2) model0: vec4<f32>,
    @location(3) model1: vec4<f32>,
    @location(4) model2: vec4<f32>,
    @location(5) model3: vec4<f32>,
    @location(6) color: vec4<f32>,
    @location(7) @interpolate(flat) shading: u32,
}

struct PointVertexInput {
    @location(0) pos: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) @interpolate(flat) shading: u32,
}

struct VertexOutput {
    @builtin(position) frag_coord: vec4<f32>,
    @location(0) frag_color: vec4<f32>,
    @location(1) @interpolate(flat) shading: u32,
    @location(2) uv: vec2<f32>,
}

@vertex
fn vs_triangle_main(in: VertexInput, instance: InstanceInput) -> VertexOutput {
    let model = mat4x4<f32>(
        instance.model0,
        instance.model1,
        instance.model2,
        instance.model3,
    );

    return VertexOutput(
        ubo.view * model * vec4<f32>(in.pos, 0.0, 1.0),
        instance.color,
        instance.shading,
        in.uv,
    );
}

@vertex
fn vs_point_main(in: PointVertexInput) -> VertexOutput {
    return VertexOutput(
        ubo.view * vec4<f32>(in.pos, 0.0, 1.0),
        in.color,
        in.shading,
        vec2<f32>(0.0),
    );
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let pos = (in.frag_coord.xy / ubo.viewport_size - 0.5) / ubo.aspect + 0.5;
    var color: vec4<f32>;

    switch in.shading {
        case 0u: { // SHADING_COLOR
            color = in.frag_color;
        }
        case 1u: { // SHADING_RAINBOW
            color = vec4<f32>(lrgb_from_hsv(vec3<f32>(pos.x * radians(360.0), 1.0, 1.0)), in.frag_color.a);
        }
        case 2u: { // SHADING_RAINBOW_SCROLL
            color = vec4<f32>(lrgb_from_hsv(vec3<f32>(pos.x * radians(360.0) + ubo.time, 1.0, 1.0)), in.frag_color.a);
        }
        default: {}
    }

    if ubo.color_correction != 0u {
        color = vec4<f32>(srgb_from_lrgb(color.rgb), color.a);
    }

    return color;
}

@fragment
fn fs_mask_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let pos = (in.frag_coord.xy / ubo.viewport_size - 0.5) / ubo.aspect + 0.5;
    var color: vec4<f32>;

    switch in.shading {
        case 0u: { // SHADING_COLOR
            color = in.frag_color;
        }
        case 1u: { // SHADING_RAINBOW
            color = vec4<f32>(lrgb_from_hsv(vec3<f32>(pos.x * radians(360.0), 1.0, 1.0)), in.frag_color.a);
        }
        case 2u: { // SHADING_RAINBOW_SCROLL
            color = vec4<f32>(lrgb_from_hsv(vec3<f32>(pos.x * radians(360.0) + ubo.time, 1.0, 1.0)), in.frag_color.a);
        }
        default: {}
    }

    if ubo.color_correction != 0u {
        color = vec4<f32>(srgb_from_lrgb(color.rgb), color.a);
    }

    color.a = textureSample(u_mask_texture, u_mask_sampler, in.uv).r;

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
