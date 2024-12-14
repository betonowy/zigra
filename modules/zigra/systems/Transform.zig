const std = @import("std");
const util = @import("utils");
const la = @import("la");

const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

pub const Data = struct {
    pos: @Vector(2, f32) = .{ 0, 0 },
    vel: @Vector(2, f32) = .{ 0, 0 },
    rot: f32 = 0,
    spin: f32 = 0,

    pub fn visualPos(self: @This(), drift: f32) @Vector(2, f32) {
        return self.pos + self.vel * la.splat(2, drift);
    }

    pub fn visualRot(self: @This(), drift: f32) f32 {
        return self.rot + self.spin * drift;
    }
};

data: util.ecs.UuidContainer(Data),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .data = util.ecs.UuidContainer(Data).init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.data.deinit();
}

pub fn createId(self: *@This(), comp: Data, uuid: util.ecs.Uuid) !u32 {
    return try self.data.tryPut(uuid, comp);
}

pub fn destroyByEntityUuid(self: *@This(), uuid: util.ecs.Uuid) void {
    self.data.remove(uuid) catch {};
}
