
vec4 unpack4xf16(uvec2 value) {
    return vec4(
        unpackHalf2x16(value.x),
        unpackHalf2x16(value.y)
    );
}
