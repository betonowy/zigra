const std = @import("std");
const utils = @import("utils");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

pub const Entity = struct {
    deinit_fn: *const EntityDeinitFn,

    pub fn deinit(self: @This(), ctx: *zigra.Context, id: u32) void {
        self.deinit_fn(self, ctx, id);
    }
};

const EntityDeinitFn = fn (self: Entity, ctx: *zigra.Context, id: u32) void;

store: utils.IdArray(Entity),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .store = utils.IdArray(Entity).init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.store.deinit();
}

pub fn destroyEntity(self: *@This(), ctx: *zigra.Context, id: u32) void {
    self.store.at(id).deinit(ctx, id);
    self.store.remove(id);
}

pub fn create(self: *@This(), deinit_fn: *const EntityDeinitFn) !u32 {
    return try self.store.put(.{ .deinit_fn = deinit_fn });
}
