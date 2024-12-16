const nk = @import("nuklear");
const root = @import("../../root.zig");
const vk_types = @import("../Vulkan/types.zig");
const std = @import("std");

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
        nk.command_image => @panic("Unimplemented"),
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
    var vertices: [4]vk_types.VertexData = undefined;

    for (0..@intCast(cmd.length)) |l| {
        inline for (vertices[0..], 0..) |*v, i| {
            v.color = nkRgba8ToF16Srgb(cmd.foreground);
            v.point = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, i);
            v.uv = std.mem.zeroes(@Vector(2, f32));
        }

        const char = @as([*]const u8, @ptrCast(&cmd.string))[l];

        try m.vulkan.pushGuiCmdChar(.{
            .char = char,
            .offset = .{
                @floatFromInt(cmd.x + @as(i32, @intCast(l * 8))),
                @floatFromInt(cmd.y),
                0,
            },
            .color = nkRgba8ToF16Srgb(cmd.foreground),
        });
    }
}

pub fn renderScissor(_: *nk.Context, cmd: *const nk.CommandScissor, m: *root.Modules) !void {
    try m.vulkan.pushGuiScissor(.{ cmd.x, cmd.y }, .{ cmd.w, cmd.h });
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

fn nkRectToPosition(w: u31, h: u31, x: i32, y: i32, comptime i: comptime_int) @Vector(3, f32) {
    std.debug.assert(i >= 0 and i < 4);
    return .{
        @floatFromInt(x + if (i == 0 or i == 2) 0 else w),
        @floatFromInt(y + if (i == 0 or i == 1) 0 else h),
        0.1,
    };
}

pub fn renderRectFilled(_: *nk.Context, cmd: *const nk.CommandRectFilled, m: *root.Modules) !void {
    var vertices: [4]vk_types.VertexData = undefined;

    inline for (vertices[0..], 0..) |*v, i| {
        v.color = nkRgba8ToF16Srgb(cmd.color);
        v.point = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, i);
        v.uv = @splat(std.math.nan(f32));
    }

    try m.vulkan.pushGuiTriangle(vertices[0..3]);
    try m.vulkan.pushGuiTriangle(vertices[1..4]);
}

fn renderRectEdge(
    _: *nk.Context,
    m: *root.Modules,
    color: @Vector(4, f16),
    p_a: @Vector(3, f32),
    p_b: @Vector(3, f32),
    c_a: @Vector(3, f32),
    c_b: @Vector(3, f32),
) !void {
    const edge: [4]vk_types.VertexData = .{
        .{ .color = color, .point = p_a + c_a, .uv = @splat(std.math.nan(f32)) },
        .{ .color = color, .point = p_b + c_a, .uv = @splat(std.math.nan(f32)) },
        .{ .color = color, .point = p_a + c_b, .uv = @splat(std.math.nan(f32)) },
        .{ .color = color, .point = p_b + c_b, .uv = @splat(std.math.nan(f32)) },
    };

    try m.vulkan.pushGuiTriangle(edge[0..3]);
    try m.vulkan.pushGuiTriangle(edge[1..4]);
}

pub fn renderRect(nk_ctx: *nk.Context, cmd: *const nk.CommandRect, m: *root.Modules) !void {
    const base_vertices: [4]@Vector(3, f32) = .{
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 0),
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 1),
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 2),
        nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, 3),
    };
    const color = nkRgba8ToF16Srgb(cmd.color);

    const correction: [3]@Vector(3, f32) = .{
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
    };

    try renderRectEdge(nk_ctx, m, color, base_vertices[0], base_vertices[1], correction[0], correction[1]);
    try renderRectEdge(nk_ctx, m, color, base_vertices[2], base_vertices[3], -correction[0], -correction[1]);
    try renderRectEdge(nk_ctx, m, color, base_vertices[0], base_vertices[2], correction[0], correction[2]);
    try renderRectEdge(nk_ctx, m, color, base_vertices[1], base_vertices[3], -correction[0], -correction[2]);
}

pub fn renderTriangleFilled(_: *nk.Context, cmd: *const nk.CommandTriangleFilled, m: *root.Modules) !void {
    const color = nkRgba8ToF16Srgb(cmd.color);

    const vertices: [3]vk_types.VertexData = .{
        .{
            .point = .{ @floatFromInt(cmd.a.x), @floatFromInt(cmd.a.y), 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
        .{
            .point = .{ @floatFromInt(cmd.b.x), @floatFromInt(cmd.b.y), 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
        .{
            .point = .{ @floatFromInt(cmd.c.x), @floatFromInt(cmd.c.y), 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
    };

    try m.vulkan.pushGuiTriangle(vertices[0..]);
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

    const vertices: [4]vk_types.VertexData = .{
        .{
            .point = .{ begin[0] + tvec[0], begin[1] + tvec[1], 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
        .{
            .point = .{ begin[0] - tvec[0], begin[1] - tvec[1], 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
        .{
            .point = .{ end[0] + tvec[0], end[1] + tvec[1], 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
        .{
            .point = .{ end[0] - tvec[0], end[1] - tvec[1], 0 },
            .color = color,
            .uv = @splat(std.math.nan(f32)),
        },
    };

    try m.vulkan.pushGuiTriangle(vertices[0..3]);
    try m.vulkan.pushGuiTriangle(vertices[1..4]);
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

        const vertices = [3]vk_types.VertexData{
            .{
                .point = .{ center[0], center[1], 0 },
                .color = color,
                .uv = @splat(std.math.nan(f32)),
            },
            .{
                .point = .{ center[0] + p_a[0], center[1] + p_a[1], 0 },
                .color = color,
                .uv = @splat(std.math.nan(f32)),
            },
            .{
                .point = .{ center[0] + p_b[0], center[1] + p_b[1], 0 },
                .color = color,
                .uv = @splat(std.math.nan(f32)),
            },
        };

        try m.vulkan.pushGuiTriangle(vertices[0..]);
    }
}
