const std = @import("std");
const zlm = @import("zlm");

pub fn lrgbFromSrgb(srgb: zlm.Vec3) zlm.Vec3 {
    return zlm.vec3(inverseGamma(srgb.x), inverseGamma(srgb.y), inverseGamma(srgb.z));
}

pub fn lrgbFromHsv(hsv: zlm.Vec3) zlm.Vec3 {
    return lrgbFromSrgb(srgbFromHsv(hsv));
}

pub fn srgbFromHsv(hsv: zlm.Vec3) zlm.Vec3 {
    const tau = zlm.toRadians(360.0);
    const hsv_mod = zlm.vec3(@mod(hsv.x, tau), hsv.y, hsv.z);
    return zlm.vec3(hsvF(hsv_mod, 5.0), hsvF(hsv_mod, 3.0), hsvF(hsv_mod, 1.0));
}

fn hsvF(hsv: zlm.Vec3, n: f32) f32 {
    const k = @mod(n + hsv.x / zlm.toRadians(60.0), 6.0);
    return hsv.z - hsv.z * hsv.y * @max(0.0, @min(k, @min(4.0 - k, 1.0)));
}

fn inverseGamma(c: f32) f32 {
    if (c <= 0.04045) {
        return c / 12.92;
    } else {
        return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
}
