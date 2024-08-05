const std = @import("std");
const utils = @import("utils");
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

data: utils.ExtIdMappedIdArray(Data),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .data = utils.ExtIdMappedIdArray(Data).init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.data.deinit();
}

pub fn createId(self: *@This(), comp: Data, entity_id: u32) !u32 {
    return try self.data.put(entity_id, comp);
}

pub fn destroyByEntityId(self: *@This(), id: u32) void {
    self.data.remove(id);
}
