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
    const slice = self.store.slice();

    std.debug.assert(slice.items(.active)[id]);

    const entity: *Entity = &slice.items(.payload)[id];
    entity.deinit(ctx, id);

    self.store.destroyId(id) catch unreachable;
}

const CreateEntityResult = struct {
    entity: *Entity,
    id: u32,
};

pub fn create(self: *@This(), deinit_fn: *const EntityDeinitFn) !CreateEntityResult {
    const id = try self.store.createId();
    const slice = self.store.slice();

    const entity: *Entity = &slice.items(.payload)[id];
    entity.deinit_fn = deinit_fn;

    return .{ .entity = entity, .id = id };
}
