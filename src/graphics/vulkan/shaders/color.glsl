float inv_gamma(float c) {
    if (c <= 0.04045) {
        return c / 12.92;
    } else {
        return pow((c + 0.055) / 1.055, 2.4);
    }
}

vec3 lrgb_from_srgb(vec3 srgb) {
    return vec3(
        inv_gamma(srgb.r),
        inv_gamma(srgb.g),
        inv_gamma(srgb.b)
    );
}

float gamma(float u) {
    if (u <= 0.0031308) {
        return 12.92 * u;
    } else {
        return (1.055 * pow(u, 1.0 / 2.4)) - 0.055;
    }
}

vec3 srgb_from_lrgb(vec3 lrgb) {
    return vec3(gamma(lrgb.r), gamma(lrgb.g), gamma(lrgb.b));
}

float hsv_f(vec3 hsv, float n) {
    float k = mod(n + hsv.x / radians(60.0), 6.0);
    return hsv.z - hsv.z * hsv.y * max(0.0, min(k, min(4.0 - k, 1.0)));
}

vec3 srgb_from_hsv(vec3 hsv) {
    const float tau = radians(360.0);
    vec3 hsv_mod = vec3(mod(hsv.x, tau), hsv.yz);
    return vec3(hsv_f(hsv_mod, 5.0), hsv_f(hsv_mod, 3.0), hsv_f(hsv_mod, 1.0));
}

vec3 lrgb_from_hsv(vec3 hsv) {
    return lrgb_from_srgb(srgb_from_hsv(hsv));
}
