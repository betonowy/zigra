const std = @import("std");

pub const Vertex = extern struct {
    pos: @Vector(2, f32),
    col: @Vector(4, f16),
    uv: @Vector(2, f32),
    tex_ref: @Vector(2, u32),
};

pub const TexRef = extern struct {
    index: u32,
    layer: u32,
};

pub const Ubo = extern struct {
    camera_pos: @Vector(2, i32),
    camera_diff: @Vector(2, i32),

    target_size: @Vector(2, u32),
    landscape_size: @Vector(2, u32),

    window_size: @Vector(2, u32),
    ambient_color: @Vector(4, f16),

    background: Background align(16),

    dui_font_tex_ref: TexRef,

    db_world_triangles_count: u32,
    db_gui_triangles_count: u32,
    db_dui_triangles_count: u32,

    pub const Background = extern struct {
        entries: [32]Entry align(16),
        count: u32,

        pub const Entry = extern struct {
            offset: @Vector(2, f32) align(16),
            influence: @Vector(2, f32),
            tex: TexRef,
        };
    };
};

// Ensure Ubo follows std140 alignment
comptime {
    checkAlignment(&.{.{ .T = Ubo, .name = "camera_pos" }}, 0);
    checkAlignment(&.{.{ .T = Ubo, .name = "camera_diff" }}, 8);
    checkAlignment(&.{.{ .T = Ubo, .name = "target_size" }}, 16);
    checkAlignment(&.{.{ .T = Ubo, .name = "landscape_size" }}, 24);
    checkAlignment(&.{.{ .T = Ubo, .name = "window_size" }}, 32);
    checkAlignment(&.{.{ .T = Ubo, .name = "ambient_color" }}, 40);

    checkAlignment(&.{
        .{ .T = Ubo, .name = "background" },
        .{ .T = Ubo.Background, .name = "entries" },
    }, 48);

    checkAlignment(&.{
        .{ .T = Ubo, .name = "background" },
        .{ .T = Ubo.Background, .name = "count" },
    }, 1072);

    checkAlignment(&.{.{ .T = Ubo, .name = "dui_font_tex_ref" }}, 1088);
    checkAlignment(&.{.{ .T = Ubo, .name = "db_world_triangles_count" }}, 1096);
}

const Pack = struct { T: type, name: []const u8 };

fn checkAlignment(fields: []const Pack, offset: comptime_int) void {
    var real_offset = 0;
    var tags: []const u8 = "";

    for (fields) |f| {
        tags = tags ++ f.name;
        real_offset += @offsetOf(f.T, f.name);
    }

    if (real_offset != offset) {
        @compileError(std.fmt.comptimePrint(
            "{s} has offset of: {}, but expected {}",
            .{ tags, real_offset, offset },
        ));
    }
}
