const nk = @import("nuklear");
const zigra = @import("../../zigra.zig");
const vk_types = @import("../Vulkan/types.zig");
const std = @import("std");

pub fn renderCallback(nk_ctx: *nk.Context, cmd: *const nk.Command, ctx: *zigra.Context) anyerror!void {
    switch (cmd.type) {
        nk.command_nop => @panic("Unimplemented"),
        nk.command_scissor => try renderScissor(nk_ctx, @ptrCast(cmd), ctx),
        nk.command_line => @panic("Unimplemented"),
        nk.command_curve => @panic("Unimplemented"),
        nk.command_rect => try renderRect(nk_ctx, @ptrCast(cmd), ctx),
        nk.command_rect_filled => try renderRectFilled(nk_ctx, @ptrCast(cmd), ctx),
        nk.command_rect_multi_color => @panic("Unimplemented"),
        nk.command_circle => @panic("Unimplemented"),
        nk.command_circle_filled => @panic("Unimplemented"),
        nk.command_arc => @panic("Unimplemented"),
        nk.command_arc_filled => @panic("Unimplemented"),
        nk.command_triangle => @panic("Unimplemented"),
        nk.command_triangle_filled => try renderTriangleFilled(nk_ctx, @ptrCast(cmd), ctx),
        nk.command_polygon => @panic("Unimplemented"),
        nk.command_polygon_filled => @panic("Unimplemented"),
        nk.command_polyline => @panic("Unimplemented"),
        nk.command_text => try renderText(nk_ctx, @ptrCast(cmd), ctx),
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

pub fn renderText(_: *nk.Context, cmd: *const nk.CommandText, ctx: *zigra.Context) !void {
    var vertices: [4]vk_types.VertexData = undefined;

    for (0..@intCast(cmd.length)) |l| {
        inline for (vertices[0..], 0..) |*v, i| {
            v.color = nkRgba8ToF16Srgb(cmd.foreground);
            v.point = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, i);
            v.uv = std.mem.zeroes(@Vector(2, f32));
        }

        const char = @as([*]const u8, @ptrCast(&cmd.string))[l];

        try ctx.systems.vulkan.pushGuiCmdChar(.{
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

pub fn renderScissor(_: *nk.Context, cmd: *const nk.CommandScissor, ctx: *zigra.Context) !void {
    try ctx.systems.vulkan.pushGuiScissor(.{ cmd.x, cmd.y }, .{ cmd.w, cmd.h });
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

pub fn renderRectFilled(_: *nk.Context, cmd: *const nk.CommandRectFilled, ctx: *zigra.Context) !void {
    var vertices: [4]vk_types.VertexData = undefined;

    inline for (vertices[0..], 0..) |*v, i| {
        v.color = nkRgba8ToF16Srgb(cmd.color);
        v.point = nkRectToPosition(cmd.w, cmd.h, cmd.x, cmd.y, i);
        v.uv = @splat(std.math.nan(f32));
    }

    try ctx.systems.vulkan.pushGuiTriangle(vertices[0..3]);
    try ctx.systems.vulkan.pushGuiTriangle(vertices[1..4]);
}

fn renderRectEdge(
    _: *nk.Context,
    ctx: *zigra.Context,
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

    try ctx.systems.vulkan.pushGuiTriangle(edge[0..3]);
    try ctx.systems.vulkan.pushGuiTriangle(edge[1..4]);
}

pub fn renderRect(nk_ctx: *nk.Context, cmd: *const nk.CommandRect, ctx: *zigra.Context) !void {
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

    try renderRectEdge(nk_ctx, ctx, color, base_vertices[0], base_vertices[1], correction[0], correction[1]);
    try renderRectEdge(nk_ctx, ctx, color, base_vertices[2], base_vertices[3], -correction[0], -correction[1]);
    try renderRectEdge(nk_ctx, ctx, color, base_vertices[0], base_vertices[2], correction[0], correction[2]);
    try renderRectEdge(nk_ctx, ctx, color, base_vertices[1], base_vertices[3], -correction[0], -correction[2]);
}

pub fn renderTriangleFilled(_: *nk.Context, cmd: *const nk.CommandTriangleFilled, ctx: *zigra.Context) !void {
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

    try ctx.systems.vulkan.pushGuiTriangle(vertices[0..]);
}
