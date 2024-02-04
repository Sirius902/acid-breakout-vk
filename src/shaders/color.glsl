float inv_gamma(float c) {
    if (c <= 0.04045) {
        return c / 12.92;
    } else {
        return pow((c + 0.055) / 1.055, 2.4);
    }
}

vec3 lrgb_from_srgb(vec3 s) {
    return vec3(
        inv_gamma(s.r),
        inv_gamma(s.g),
        inv_gamma(s.b)
    );
}

float gamma(float u) {
    if (u <= 0.0031308) {
        return 12.92 * u;
    } else {
        return (1.055 * pow(u, 1.0 / 2.4)) - 0.055;
    }
}

vec3 srgb_from_lrgb(vec3 c) {
    return vec3(gamma(c.r), gamma(c.g), gamma(c.b));
}

vec3 srgb_from_hsv(vec3 in_hsv) {
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

vec3 lrgb_from_hsv(vec3 c) {
    return lrgb_from_srgb(srgb_from_hsv(c));
}
