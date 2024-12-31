const std = @import("std");
const utils = @import("util");
const lifetime = @import("lifetime");
const tracy = @import("tracy");
const la = @import("la");

const root = @import("../root.zig");
const systems = @import("../systems.zig");
const common = @import("common.zig");

const Layer = struct {
    offset: @Vector(2, i32) = .{ 0, 0 },
    camera_influence: @Vector(2, f32) = .{ 0.5, 0.5 },
    depth: f32,

    id_vk_sprite: systems.Vulkan.Atlas.TextureReference,
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
        try m.vulkan.pushBkgEntry(.{
            .influence = layer.camera_influence,
            .offset = @floatFromInt(layer.offset),
            .tex = .{
                .index = layer.id_vk_sprite.index,
                .layer = layer.id_vk_sprite.layer,
            },
        });
    }
}
