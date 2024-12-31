// This file must be kept in sync with `modules/zigra/systems/Vulkan/shader_io.zig`

struct UboTexRef {
    uint index;
    uint layer;
};

struct UboBackgroundEntry {
    vec2 offset;
    vec2 influence;
    UboTexRef tex;
};

struct UboBackground {
    UboBackgroundEntry entries[32];
    uint count;
};

#define UBO_DEF                            \
Ubo {                                      \
    ivec2 camera_pos;                      \
    ivec2 camera_diff;                     \
                                           \
    uvec2 target_size;                     \
    uvec2 landscape_size;                  \
    uvec2 window_size;                     \
    uvec2 ambient_color_4xf16;             \
                                           \
    UboBackground background;              \
                                           \
    UboTexRef dui_font_tex_ref;            \
}
