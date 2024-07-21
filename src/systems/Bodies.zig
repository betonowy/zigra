const std = @import("std");
const utils = @import("utils");

const lifetime = @import("../../lifetime.zig");
const zigra = @import("../../zigra.zig");

pub const Rigid = struct {};

pub const Character = struct {};

pub const Point = struct {
    weight: f32 = 1,
    id_entity: u32 = 0,
    id_transform: u32 = 0,

    acc: @Vector(2, f32) = .{ 0, 0 },
    mom: f32 = 0,
};

bodies_point: utils.IdStore(Point),
entity_id_map: std.AutoHashMap(u32, u32),

pub fn simulatePointBodies(self: *@This(), _: *lifetime.ContextBase) !void {
    _ = self; // autofix
}
