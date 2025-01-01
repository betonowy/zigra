const nk = @import("nuklear");
const root = @import("../../root.zig");
const Vulkan = @import("../Vulkan.zig");
const std = @import("std");
const la = @import("la");

pub fn renderCallback(nk_ctx: *nk.Context, cmd: *const nk.Command, m: *root.Modules) anyerror!void {
    switch (cmd.type) {
        nk.command_nop => @panic("Unimplemented"),
        nk.command_scissor => try renderScissor(nk_ctx, @ptrCast(cmd), m),
        nk.command_line => try renderLine(nk_ctx, @ptrCast(cmd), m),
        nk.command_curve => @panic("Unimplemented"),
        nk.command_rect => try renderRect(nk_ctx, @ptrCast(cmd), m),
        nk.command_rect_filled => try renderRectFilled(nk_ctx, @ptrCast(cmd), m),
        nk.command_rect_multi_color => @panic("Unimplemented"),
        nk.command_circle => @panic("Unimplemented"),
        nk.command_circle_filled => try renderCircleFilled(nk_ctx, @ptrCast(cmd), m),
        nk.command_arc => @panic("Unimplemented"),
        nk.command_arc_filled => @panic("Unimplemented"),
        nk.command_triangle => @panic("Unimplemented"),
        nk.command_triangle_filled => try renderTriangleFilled(nk_ctx, @ptrCast(cmd), m),
        nk.command_polygon => @panic("Unimplemented"),
        nk.command_polygon_filled => @panic("Unimplemented"),
        nk.command_polyline => @panic("Unimplemented"),
        nk.command_text => try renderText(nk_ctx, @ptrCast(cmd), m),
        nk.command_image => try renderImage(nk_ctx, @ptrCast(cmd), m),
        nk.command_custom => @panic("Unimplemented"),
        else => @panic("Invalid NK draw command"),
    }
}

fn nkByteToF16(byte: u8) f16 {
    return @as(f16, @floatFromInt(byte)) * (1.0 / 255.0);
}

fn nkRgba8ToF16(color: nk.Color) @Vector(4, f16) {
    return .{ nkByteToF16(color.r), nkByteToF16(color.g), nkByteToF16(color.b), nkByteToF16(color.a) };
}

pub fn renderText(_: *nk.Context, cmd: *const nk.CommandText, m: *root.Modules) !void {
    for (0..@intCast(cmd.length)) |l| {
        const font_ref: @Vector(2, u32) = .{
            m.nuklear.font_ref.layer,
            m.nuklear.font_ref.index,
        };

        const char = @as([*]const u8, @ptrCast(&cmd.string))[l];

        const font_h_count = 16;
        const font_height = 8;
        const font_width = 8;

        const base_char_offset: @Vector(2, f32) = .{
            @floatFromInt(@as(i32, @intCast((char % font_h_count) * font_width))),
            @floatFromInt(@as(i32, @intCast((char / font_h_count) * font_height))),
        };

        const base_char_extent: @Vector(2, f32) = .{
            @floatFromInt(font_width),
            @floatFromInt(font_height),
        };

        const color = nkRgba8ToF16Srgb(cmd.foreground);

        const vertices: [4]Vulkan.GuiVertex = .{
            .{
                .col = color,
                .pos = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 0) +
                    @Vector(2, f32){ @floatFromInt(l * font_width), 0 },
                .uv = base_char_offset,
                .tex_ref = font_ref,
            },
            .{
                .col = color,
                .pos = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 0) +
                    @Vector(2, f32){ base_char_extent[0], 0 } +
                    @Vector(2, f32){ @floatFromInt(l * font_width), 0 },
                .uv = base_char_offset + @Vector(2, f32){ base_char_extent[0], 0 },
                .tex_ref = font_ref,
            },
            .{
                .col = color,
                .pos = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 0) +
                    @Vector(2, f32){ 0, base_char_extent[1] } +
                    @Vector(2, f32){ @floatFromInt(l * font_width), 0 },
                .uv = base_char_offset + @Vector(2, f32){ 0, base_char_extent[1] },
                .tex_ref = font_ref,
            },
            .{
                .col = color,
                .pos = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 0) +
                    @Vector(2, f32){ base_char_extent[0], base_char_extent[1] } +
                    @Vector(2, f32){ @floatFromInt(l * font_width), 0 },
                .uv = base_char_offset + @Vector(2, f32){ base_char_extent[0], base_char_extent[1] },
                .tex_ref = font_ref,
            },
        };

        try m.vulkan.pushGuiVertices(vertices[0..3]);
        try m.vulkan.pushGuiVertices(vertices[1..4]);
    }
}

pub fn renderScissor(_: *nk.Context, cmd: *const nk.CommandScissor, m: *root.Modules) !void {
    try m.vulkan.impl.currentFrameDataPtr().dbs.dui.pushScissor(.{
        .offset = .{ cmd.x, cmd.y },
        .extent = .{ cmd.w, cmd.h },
    });
}

fn nkRgba8ToF16Srgb(color: nk.Color) @Vector(4, f16) {
    var v = @Vector(4, f32){
        nkByteToF16(color.r),
        nkByteToF16(color.g),
        nkByteToF16(color.b),
        nkByteToF16(color.a),
    };

    inline for (0..4) |i| v[i] = std.math.pow(f32, v[i], 2.2);

    return @floatCast(v);
}

fn nkRectToPosition(w: u31, h: u31, x: i32, y: i32, comptime i: comptime_int) @Vector(2, f32) {
    std.debug.assert(i >= 0 and i < 4);
    return .{
        @floatFromInt(x + if (i == 0 or i == 2) 0 else w),
        @floatFromInt(y + if (i == 0 or i == 1) 0 else h),
    };
}

pub fn renderRectFilled(_: *nk.Context, cmd: *const nk.CommandRectFilled, m: *root.Modules) !void {
    var vertices: [4]Vulkan.GuiVertex = undefined;

    inline for (vertices[0..], 0..) |*v, i| {
        v.col = nkRgba8ToF16Srgb(cmd.color);
        v.pos = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, i);
        v.uv = @splat(std.math.nan(f32));
    }

    try m.vulkan.pushGuiVertices(vertices[0..3]);
    try m.vulkan.pushGuiVertices(vertices[1..4]);
}

fn renderRectEdge(
    _: *nk.Context,
    m: *root.Modules,
    color: @Vector(4, f16),
    p_a: @Vector(2, f32),
    p_b: @Vector(2, f32),
    c_a: @Vector(2, f32),
    c_b: @Vector(2, f32),
) !void {
    const edge: [4]Vulkan.GuiVertex = .{
        .{ .col = color, .pos = p_a + c_a, .uv = @splat(std.math.nan(f32)), .tex_ref = undefined },
        .{ .col = color, .pos = p_b + c_a, .uv = @splat(std.math.nan(f32)), .tex_ref = undefined },
        .{ .col = color, .pos = p_a + c_b, .uv = @splat(std.math.nan(f32)), .tex_ref = undefined },
        .{ .col = color, .pos = p_b + c_b, .uv = @splat(std.math.nan(f32)), .tex_ref = undefined },
    };

    try m.vulkan.pushGuiVertices(edge[0..3]);
    try m.vulkan.pushGuiVertices(edge[1..4]);
}

pub fn renderRect(nk_ctx: *nk.Context, cmd: *const nk.CommandRect, m: *root.Modules) !void {
    const base_vertices: [4]@Vector(2, f32) = .{
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 0),
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 1),
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 2),
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 3),
    };
    const color = nkRgba8ToF16Srgb(cmd.color);

    const correction: [3]@Vector(2, f32) = .{
        .{ 0.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 0.0 },
    };

    try renderRectEdge(nk_ctx, m, color, base_vertices[0], base_vertices[1], correction[0], correction[1]);
    try renderRectEdge(nk_ctx, m, color, base_vertices[2], base_vertices[3], -correction[0], -correction[1]);
    try renderRectEdge(nk_ctx, m, color, base_vertices[0], base_vertices[2], correction[0], correction[2]);
    try renderRectEdge(nk_ctx, m, color, base_vertices[1], base_vertices[3], -correction[0], -correction[2]);
}

pub fn renderTriangleFilled(_: *nk.Context, cmd: *const nk.CommandTriangleFilled, m: *root.Modules) !void {
    const color = nkRgba8ToF16Srgb(cmd.color);

    const vertices: [3]Vulkan.GuiVertex = .{
        .{
            .pos = .{ @floatFromInt(cmd.a.x), @floatFromInt(cmd.a.y) },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
        .{
            .pos = .{ @floatFromInt(cmd.b.x), @floatFromInt(cmd.b.y) },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
        .{
            .pos = .{ @floatFromInt(cmd.c.x), @floatFromInt(cmd.c.y) },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
    };

    try m.vulkan.pushGuiVertices(vertices[0..]);
}

pub fn renderLine(_: *nk.Context, cmd: *const nk.CommandLine, m: *root.Modules) !void {
    const begin = @Vector(2, f32){ @floatFromInt(cmd.begin.x), @floatFromInt(cmd.begin.y) };
    const end = @Vector(2, f32){ @floatFromInt(cmd.end.x), @floatFromInt(cmd.end.y) };
    const color = nkRgba8ToF16Srgb(cmd.color);
    const width: f32 = @floatFromInt(cmd.line_thickness);

    const diff = (end - begin);
    const len = std.math.sqrt(@reduce(.Add, diff * diff));
    const dir = diff / @as(@Vector(2, f32), @splat(len));
    const tvec = @Vector(2, f32){ -dir[1], dir[0] } * @as(@Vector(2, f32), @splat(0.5 * width));

    const vertices: [4]Vulkan.GuiVertex = .{
        .{
            .pos = .{ begin[0] + tvec[0], begin[1] + tvec[1] },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
        .{
            .pos = .{ begin[0] - tvec[0], begin[1] - tvec[1] },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
        .{
            .pos = .{ end[0] + tvec[0], end[1] + tvec[1] },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
        .{
            .pos = .{ end[0] - tvec[0], end[1] - tvec[1] },
            .col = color,
            .uv = @splat(std.math.nan(f32)),
            .tex_ref = undefined,
        },
    };

    try m.vulkan.pushGuiVertices(vertices[0..3]);
    try m.vulkan.pushGuiVertices(vertices[1..4]);
}

pub fn renderCircleFilled(_: *nk.Context, cmd: *const nk.CommandCircleFilled, m: *root.Modules) !void {
    const ul: @Vector(2, f32) = .{
        @floatFromInt(cmd.x),
        @floatFromInt(cmd.y),
    };

    const br: @Vector(2, f32) = .{
        @floatFromInt(cmd.x + @as(i32, @intCast(cmd.w))),
        @floatFromInt(cmd.y + @as(i32, @intCast(cmd.h))),
    };

    const center = (ul + br) * @as(@Vector(2, f32), @splat(0.5));
    const radius = br - center;

    const segments: usize = @intFromFloat(4 + (radius[0] + radius[1]));
    const color = nkRgba8ToF16Srgb(cmd.color);

    for (0..segments) |i| {
        const p_a: @Vector(2, f32) = .{
            radius[0] * @sin(@as(f32, @floatFromInt(i + 0)) * 2 * std.math.pi / @as(f32, @floatFromInt(segments))),
            radius[1] * @cos(@as(f32, @floatFromInt(i + 0)) * 2 * std.math.pi / @as(f32, @floatFromInt(segments))),
        };

        const p_b: @Vector(2, f32) = .{
            radius[0] * @sin(@as(f32, @floatFromInt(i + 1)) * 2 * std.math.pi / @as(f32, @floatFromInt(segments))),
            radius[1] * @cos(@as(f32, @floatFromInt(i + 1)) * 2 * std.math.pi / @as(f32, @floatFromInt(segments))),
        };

        const vertices = [3]Vulkan.GuiVertex{
            .{
                .pos = .{ center[0], center[1] },
                .col = color,
                .uv = @splat(std.math.nan(f32)),
                .tex_ref = undefined,
            },
            .{
                .pos = .{ center[0] + p_a[0], center[1] + p_a[1] },
                .col = color,
                .uv = @splat(std.math.nan(f32)),
                .tex_ref = undefined,
            },
            .{
                .pos = .{ center[0] + p_b[0], center[1] + p_b[1] },
                .col = color,
                .uv = @splat(std.math.nan(f32)),
                .tex_ref = undefined,
            },
        };

        try m.vulkan.pushGuiVertices(vertices[0..]);
    }
}

pub fn renderImage(_: *nk.Context, cmd: *const nk.CommandImage, m: *root.Modules) !void {
    const pivot: @Vector(2, f32) = .{ @floatFromInt(cmd.x), @floatFromInt(cmd.y) };
    const layout_size: @Vector(2, f32) = .{ @floatFromInt(cmd.w), @floatFromInt(cmd.h) };
    const img_size: @Vector(2, f32) = .{ @floatFromInt(cmd.img.w), @floatFromInt(cmd.img.h) };
    const img_ul: @Vector(2, f32) = .{ @floatFromInt(cmd.img.region[0]), @floatFromInt(cmd.img.region[1]) };
    const img_br: @Vector(2, f32) = .{ @floatFromInt(cmd.img.region[2]), @floatFromInt(cmd.img.region[3]) };

    const effective_size = @min(layout_size, la.zeroExtend(2, img_size));

    const vertices = [_]Vulkan.GuiVertex{
        .{
            .pos = pivot + effective_size * @Vector(2, f32){ 0, 0 },
            .col = .{ 1, 1, 1, 1 },
            .uv = .{ img_ul[0], img_ul[1] },
            .tex_ref = undefined,
        },
        .{
            .pos = pivot + effective_size * @Vector(2, f32){ 1, 0 },
            .col = .{ 1, 1, 1, 1 },
            .uv = .{ img_br[0], img_ul[1] },
            .tex_ref = undefined,
        },
        .{
            .pos = pivot + effective_size * @Vector(2, f32){ 0, 1 },
            .col = .{ 1, 1, 1, 1 },
            .uv = .{ img_ul[0], img_br[1] },
            .tex_ref = undefined,
        },
        .{
            .pos = pivot + effective_size * @Vector(2, f32){ 1, 1 },
            .col = .{ 1, 1, 1, 1 },
            .uv = .{ img_br[0], img_br[1] },
            .tex_ref = undefined,
        },
    };

    try m.vulkan.pushGuiVertices(vertices[0..3]);
    try m.vulkan.pushGuiVertices(vertices[1..4]);
}
