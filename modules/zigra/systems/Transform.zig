const std = @import("std");
const utils = @import("utils");

const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

pub const Data = struct {
    pos: @Vector(2, f32) = .{ 0, 0 },
    vel: @Vector(2, f32) = .{ 0, 0 },
    rot: f32 = 0,
    spin: f32 = 0,
    visual: struct {
        pos: @Vector(2, f32) = .{ 0, 0 },
        rot: f32 = 0,
    } = .{},
};

data: utils.ExtIdMappedIdArray(Data),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .data = utils.ExtIdMappedIdArray(Data).init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.data.deinit();
}

pub fn calculateVisualPositions(self: *@This(), ctx_base: *lifetime.ContextBase) !void {
    const ctx = ctx_base.parent(zigra.Context);
    const drift = ctx.systems.time.tickDrift();
    var iterator = self.data.iterator();

    while (iterator.next()) |t| {
        t.visual.pos = t.pos + t.vel * @as(@Vector(2, f32), @splat(drift));
        t.visual.rot = t.rot + t.spin * drift;
    }
}

pub fn createId(self: *@This(), comp: Data, entity_id: u32) !u32 {
    return try self.data.put(entity_id, comp);
}

pub fn destroyByEntityId(self: *@This(), id: u32) void {
    self.data.remove(id);
}
