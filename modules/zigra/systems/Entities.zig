const std = @import("std");
const util = @import("util");
const lifetime = @import("lifetime");
const root = @import("../root.zig");
const common = @import("common.zig");

pub const Entity = struct {
    on_deinit_loop: util.cb.LinkedParent(OnDeinitLoopFn) = .{},
    vt: *const Vt,

    pub const Vt = struct {
        deinit_fn: *const DeinitFn,
        name: [:0]const u8,
    };

    pub fn deinit(self: *@This(), m: *root.Modules, uuid: util.ecs.Uuid) void {
        self.on_deinit_loop.callAll(.{ m, uuid });
        self.on_deinit_loop.node.unlink();
        self.vt.deinit_fn(self, m, uuid);
    }

    pub const DeinitFn = fn (self: *Entity, m: *root.Modules, uuid: util.ecs.Uuid) void;
    pub const OnDeinitLoopFn = fn (self: *anyopaque, m: *root.Modules, uuid: util.ecs.Uuid) void;
};

pub const DeinitLoopNode = util.cb.LinkedChild(Entity.OnDeinitLoopFn);

generator: util.ecs.UuidGenerator = .{},
store: util.ecs.UuidMaster(Entity),
uuids_to_destroy_later: std.ArrayList(util.ecs.Uuid),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .store = util.ecs.UuidMaster(Entity).init(allocator),
        .uuids_to_destroy_later = std.ArrayList(util.ecs.Uuid).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.uuids_to_destroy_later.deinit();
    self.store.deinit();
}

pub fn destroyEntity(self: *@This(), m: *root.Modules, uuid: util.ecs.Uuid) void {
    (self.store.get(uuid) orelse return).deinit(m, uuid);
    self.store.destroy(uuid) catch {};
}

pub fn deferDestroyEntity(self: *@This(), uuid: util.ecs.Uuid) !void {
    try self.uuids_to_destroy_later.append(uuid);
}

pub fn executePendingDestructions(self: *@This(), m: *root.Modules) !void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();
    for (self.uuids_to_destroy_later.items) |id| self.destroyEntity(m, id);
    self.uuids_to_destroy_later.clearRetainingCapacity();
}

pub fn create(self: *@This(), vt: *const Entity.Vt) !util.ecs.Uuid {
    return try self.store.create(&self.generator, 0, .{ .vt = vt });
}
