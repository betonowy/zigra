const std = @import("std");
const utils = @import("util");
const lifetime = @import("lifetime");
const tracy = @import("tracy");
const la = @import("la");

const root = @import("../root.zig");
const systems = @import("../systems.zig");
const vk_types = @import("Vulkan/Ctx/types.zig");
const common = @import("common.zig");

const Layer = struct {
    offset: @Vector(2, i32) = .{ 0, 0 },
    camera_influence: @Vector(2, f32) = .{ 0.5, 0.5 },
    depth: f32,

    id_vk_sprite: ?u32,
    bottom_gradient: ?@Vector(4, f16) = null,
    top_gradient: ?@Vector(4, f16) = null,
};

layers: utils.IdArray(Layer),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .layers = utils.IdArray(Layer).init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.layers.deinit();
}

pub fn createId(self: *@This(), comp: Layer) !u32 {
    return try self.layers.put(comp);
}

pub fn destroyById(self: *@This(), id: u32) void {
    self.layers.remove(id);
}

pub fn render(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    var iterator = self.layers.iterator();

    while (iterator.next()) |layer| {
        const cam_offset_f32: @Vector(2, f32) = @floatFromInt(m.vulkan.impl.camera_pos);
        const influenced_offset: @Vector(2, i32) = @intFromFloat(cam_offset_f32 * layer.camera_influence);

        const view_width = 320; // TODO
        const left_boundary = m.vulkan.impl.camera_pos[0] - view_width / 2;
        const center = m.vulkan.impl.camera_pos[1];

        const calculated_offset = layer.offset + @Vector(2, i32){ view_width / 2, 0 } - influenced_offset;

        if (layer.id_vk_sprite) |id| {
            const rect = m.vulkan.impl.atlas.getRectById(id);
            const count = view_width / rect.extent.width + 1;

            const mod_offset: @Vector(2, u32) = @intCast(@mod(calculated_offset, @Vector(2, i32){
                @intCast(rect.extent.width),
                @intCast(rect.extent.height),
            }));

            for (0..count + 1) |i| {
                const offset = @Vector(2, f32){
                    @floatFromInt( //
                        @as(i32, @intCast(mod_offset[0])) +
                        @as(i32, @intCast(rect.extent.width)) *
                        @as(i32, @intCast(i)) + left_boundary -
                        @as(i32, @intCast(rect.extent.width / 2))),
                    @floatFromInt(calculated_offset[1] + center),
                };

                try m.vulkan.pushCmdVertices(&createSprite(m, offset, layer.depth, id));
            }
        }

        const y = if (layer.id_vk_sprite) |id| m.vulkan.impl.atlas.getRectById(id).extent.height else 0;

        if (layer.bottom_gradient) |color| {
            const offset = @Vector(2, f32){
                @floatFromInt(-view_width),
                @floatFromInt(center + calculated_offset[1] + @as(i32, @intCast(y / 2))),
            };

            const ul: @Vector(2, i32) = .{ @intCast(left_boundary), 0 };
            const br: @Vector(2, i32) = .{ @intCast(left_boundary + 2 * view_width), std.math.maxInt(i32) };

            try m.vulkan.pushCmdVertices(&createRect(offset, layer.depth, ul, br, color));
        }

        if (layer.top_gradient) |color| {
            const offset = @Vector(2, f32){
                @floatFromInt(-view_width),
                @floatFromInt(center + calculated_offset[1] - @as(i32, @intCast(y / 2))),
            };

            const ul: @Vector(2, i32) = .{ @intCast(left_boundary), std.math.minInt(i32) };
            const br: @Vector(2, i32) = .{ @intCast(left_boundary + 2 * view_width), 0 };

            try m.vulkan.pushCmdVertices(&createRect(offset, layer.depth, ul, br, color));
        }
    }
}

fn createSprite(m: *root.Modules, pos: @Vector(2, f32), depth: f32, sprite_id: u32) [6]vk_types.VertexData {
    const rect = m.vulkan.impl.atlas.getRectById(sprite_id);

    const w = @as(f32, @floatFromInt(rect.extent.width)) * 0.5;
    const h = @as(f32, @floatFromInt(rect.extent.height)) * 0.5;

    const vx = @Vector(2, f32){ w, 0 };
    const vy = @Vector(2, f32){ 0, h };

    const p0 = -vx - vy + pos;
    const p1 = vx - vy + pos;
    const p2 = -vx + vy + pos;
    const p3 = vx + vy + pos;

    const v0 = vk_types.VertexData{
        .point = .{ p0[0], p0[1], depth },
        .color = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x),
            @floatFromInt(rect.offset.y),
        },
    };

    const v1 = vk_types.VertexData{
        .point = .{ p1[0], p1[1], depth },
        .color = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x + @as(i32, @intCast(rect.extent.width))),
            @floatFromInt(rect.offset.y),
        },
    };

    const v2 = vk_types.VertexData{
        .point = .{ p2[0], p2[1], depth },
        .color = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x),
            @floatFromInt(rect.offset.y + @as(i32, @intCast(rect.extent.height))),
        },
    };

    const v3 = vk_types.VertexData{
        .point = .{ p3[0], p3[1], depth },
        .color = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x + @as(i32, @intCast(rect.extent.width))),
            @floatFromInt(rect.offset.y + @as(i32, @intCast(rect.extent.height))),
        },
    };

    return .{ v0, v1, v2, v1, v2, v3 };
}

fn createRect(pos: @Vector(2, f32), depth: f32, ul: @Vector(2, i32), br: @Vector(2, i32), color: @Vector(4, f16)) [6]vk_types.VertexData {
    const ul_f32: @Vector(2, f32) = @floatFromInt(ul);
    const br_f32: @Vector(2, f32) = @floatFromInt(br);

    const p0 = @Vector(2, f32){ ul_f32[0], ul_f32[1] } + pos;
    const p1 = @Vector(2, f32){ br_f32[0], ul_f32[1] } + pos;
    const p2 = @Vector(2, f32){ ul_f32[0], br_f32[1] } + pos;
    const p3 = @Vector(2, f32){ br_f32[0], br_f32[1] } + pos;

    const v0 = vk_types.VertexData{
        .point = .{ p0[0], p0[1], depth },
        .color = color,
        .uv = .{ std.math.nan(f32), std.math.nan(f32) },
    };

    const v1 = vk_types.VertexData{
        .point = .{ p1[0], p1[1], depth },
        .color = color,
        .uv = .{ std.math.nan(f32), std.math.nan(f32) },
    };

    const v2 = vk_types.VertexData{
        .point = .{ p2[0], p2[1], depth },
        .color = color,
        .uv = .{ std.math.nan(f32), std.math.nan(f32) },
    };

    const v3 = vk_types.VertexData{
        .point = .{ p3[0], p3[1], depth },
        .color = color,
        .uv = .{ std.math.nan(f32), std.math.nan(f32) },
    };

    return .{ v0, v1, v2, v1, v2, v3 };
}
