const std = @import("std");
const utils = @import("utils");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

pub const Entity = struct {
    deinit_fn: *const DeinitFn,
    on_deinit_loop: utils.cb.LinkedParent(OnDeinitLoopFn) = .{},

    pub fn deinit(self: *@This(), ctx: *zigra.Context, id: u32) void {
        self.on_deinit_loop.callAll(.{ ctx, id });
        self.on_deinit_loop.node.unlink();
        self.deinit_fn(self, ctx, id);
    }

    pub const DeinitFn = fn (self: *Entity, ctx: *zigra.Context, id: u32) void;
    pub const OnDeinitLoopFn = fn (self: *anyopaque, ctx: *zigra.Context, id: u32) void;
};

pub const DeinitLoopNode = utils.cb.LinkedChild(Entity.OnDeinitLoopFn);

store: utils.IdArray(Entity),
ids_to_destroy_later: std.ArrayList(u32),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .store = utils.IdArray(Entity).init(allocator),
        .ids_to_destroy_later = std.ArrayList(u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.store.deinit();
}

pub fn destroyEntity(self: *@This(), ctx: *zigra.Context, id: u32) void {
    self.store.at(id).deinit(ctx, id);
    self.store.remove(id);
}

pub fn tryDestroyEntity(self: *@This(), ctx: *zigra.Context, id: u32) void {
    (self.store.tryAt(id) orelse return).deinit(ctx, id);
    self.store.remove(id);
}

pub fn deferDestroyEntity(self: *@This(), id: u32) !void {
    try self.ids_to_destroy_later.append(id);
}

pub fn executePendingDestructions(self: *@This(), ctx: *lifetime.ContextBase) !void {
    for (self.ids_to_destroy_later.items) |id| self.tryDestroyEntity(ctx.parent(zigra.Context), id);
    self.ids_to_destroy_later.clearRetainingCapacity();
}

pub fn create(self: *@This(), deinit_fn: *const Entity.DeinitFn) !u32 {
    return try self.store.put(.{ .deinit_fn = deinit_fn });
}
