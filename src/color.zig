const std = @import("std");
const zlm = @import("zlm");

pub fn lrgbFromSrgb(color: zlm.Vec3) zlm.Vec3 {
    return zlm.vec3(inverseGamma(color.x), inverseGamma(color.y), inverseGamma(color.z));
}

pub fn lrgbFromHsv(color: zlm.Vec3) zlm.Vec3 {
    return lrgbFromSrgb(srgbFromHsv(color));
}

pub fn srgbFromHsv(color: zlm.Vec3) zlm.Vec3 {
    const tau = zlm.toRadians(360.0);
    const hsv = zlm.vec3(@mod(color.x, tau), @mod(color.y, tau), @mod(color.z, tau));
    const chroma = hsv.y * hsv.z;
    const x = chroma * (1 - @abs(@mod(hsv.x / zlm.toRadians(60.0), 2) - 1));
    const m = hsv.z - chroma;

    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    if (hsv.x >= 0 and hsv.x < zlm.toRadians(60.0)) {
        r = chroma;
        g = x;
        b = 0;
    } else if (hsv.x >= zlm.toRadians(60.0) and hsv.x < zlm.toRadians(120.0)) {
        r = x;
        g = chroma;
        b = 0;
    } else if (hsv.x >= zlm.toRadians(120.0) and hsv.x < zlm.toRadians(180.0)) {
        r = 0;
        g = chroma;
        b = x;
    } else if (hsv.x >= zlm.toRadians(180.0) and hsv.x < zlm.toRadians(240.0)) {
        r = 0;
        g = x;
        b = chroma;
    } else if (hsv.x >= zlm.toRadians(240.0) and hsv.x < zlm.toRadians(300.0)) {
        r = x;
        g = 0;
        b = chroma;
    } else if (hsv.x >= zlm.toRadians(300.0) and hsv.x < zlm.toRadians(360.0)) {
        r = chroma;
        g = 0;
        b = x;
    }

    return zlm.vec3(r + m, g + m, b + m);
}

fn inverseGamma(c: f32) f32 {
    if (c <= 0.04045) {
        return c / 12.92;
    } else {
        return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
}
