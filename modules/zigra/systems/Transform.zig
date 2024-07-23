const std = @import("std");
const utils = @import("utils");

const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

pub const Transform = struct {
    pos: @Vector(2, f32) = .{ 0, 0 },
    vel: @Vector(2, f32) = .{ 0, 0 },
    rot: f32 = 0,
    spin: f32 = 0,
    visual: struct {
        pos: @Vector(2, f32) = .{ 0, 0 },
        rot: f32 = 0,
    } = .{},
};

transforms: utils.IdStore(Transform),
entity_id_map: std.AutoHashMap(u32, u32),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .transforms = utils.IdStore(Transform).init(allocator),
        .entity_id_map = std.AutoHashMap(u32, u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.entity_id_map.deinit();
    self.transforms.deinit();
}

pub fn calculateVisualPositions(self: *@This(), ctx_base: *lifetime.ContextBase) !void {
    const ctx = ctx_base.parent(zigra.Context);
    const drift = ctx.systems.time.tickDrift();
    var iterator = self.transforms.iterator();

    while (iterator.next()) |fields| {
        fields.payload.visual.pos = fields.payload.pos + fields.payload.vel * @as(@Vector(2, f32), @splat(drift));
        fields.payload.visual.rot = fields.payload.rot + fields.payload.spin * drift;
    }
}

pub fn createId(self: *@This(), comp: Transform, entity_id: u32) !u32 {
    const internal_id = try self.transforms.push(comp);
    try self.entity_id_map.put(entity_id, internal_id);
    return internal_id;
}

pub fn destroyByEntityId(self: *@This(), id: u32) void {
    const kv = self.entity_id_map.fetchRemove(id) orelse @panic("Entity id not found");
    self.transforms.destroyId(kv.value) catch @panic("Transform id not found");
}
