float srgb_to_rgb_component(float c) {
    if (c <= 0.04045) {
        return c / 12.92;
    } else {
        return pow((c + 0.055) / 1.055, 2.4);
    }
}

vec3 srgb_to_rgb(vec3 s) {
    return vec3(
        srgb_to_rgb_component(s.r),
        srgb_to_rgb_component(s.g),
        srgb_to_rgb_component(s.b)
    );
}
