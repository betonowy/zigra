const std = @import("std");
const util = @import("util");
const la = @import("la");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const root = @import("../root.zig");
const common = @import("common.zig");

const log = std.log.scoped(.Camera);

id_entity: util.ecs.Uuid = undefined,
id_transform: u32 = undefined,

target: Target = .null,

const attract_acc = 300;
const look_ahead_delay = 0.66;

const Target = union(enum) {
    const Entity = struct { node: systems.Entities.DeinitLoopNode, uuid: util.ecs.Uuid };

    null: void,
    pos: @Vector(2, f32),
    entity: Entity,
};

pub fn cameraEntityDeinit(_: *systems.Entities.Entity, m: *root.Modules, uuid: util.ecs.Uuid) void {
    m.transform.destroyByEntityUuid(uuid);
}

pub fn targetDeinitLoopCb(node: *anyopaque, _: *root.Modules, _: util.ecs.Uuid) void {
    const entity: *Target.Entity = @fieldParentPtr("node", @as(*systems.Entities.DeinitLoopNode, @alignCast(@ptrCast(node))));
    const target: *Target = @fieldParentPtr("entity", entity);
    const self: *@This() = @fieldParentPtr("target", target);
    self.target = .null;
}

pub fn init(m: *root.Modules) !@This() {
    var self = @This(){};

    self.id_entity = try m.entities.create(&.{
        .deinit_fn = &cameraEntityDeinit,
        .name = "camera",
    });

    self.id_transform = try m.transform.createId(.{}, self.id_entity);
    self.target = .{ .pos = .{ 0, 0 } };

    return self;
}

pub fn tick(self: *@This(), m: *root.Modules) !void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    const transform = self.getCameraTransform(m);

    const time_constant = m.time.tickDelay();

    const pos_target = switch (self.target) {
        .null => transform.pos,
        .pos => |pos| pos,
        .entity => |e| if (m.transform.data.getByUuid(e.uuid)) |tf| tf.pos else return error.InvalidEid,
    };

    const acc_target_raw = la.splat(2, attract_acc * time_constant) * (pos_target - transform.pos);

    const pos_predicted = util.integrators.verletPosition(
        @Vector(2, f32),
        transform.pos,
        transform.vel,
        acc_target_raw,
        look_ahead_delay,
    );

    const acc_target_corrected = la.splat(2, attract_acc * time_constant) * (pos_target - pos_predicted);

    transform.pos = util.integrators.verletPosition(
        @Vector(2, f32),
        transform.pos,
        transform.vel,
        acc_target_corrected + acc_target_raw,
        time_constant,
    );

    transform.vel = util.integrators.verletVelocity(
        @Vector(2, f32),
        transform.vel,
        acc_target_corrected + acc_target_raw,
        time_constant,
    );
}

pub fn update(self: *@This(), m: *root.Modules) !void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    const transform = self.getCameraTransform(m);
    const pos = transform.visualPos(m.time.tickDrift());
    m.vulkan.setCameraPosition(@intFromFloat(pos));
    m.audio.mixer.setListenerPos(pos) catch log.warn("Failed to push setListenerPos", .{});
}

pub fn getCameraTransform(self: *@This(), m: *root.Modules) *systems.Transform.Data {
    return m.transform.data.getById(self.id_transform);
}

pub fn clearTarget(self: *@This()) void {
    self.cleanupTarget();
    self.target = .null;
}

const SetTarget = union(enum) {
    null: void,
    pos: @Vector(2, f32),
    id_entity: struct {
        id: util.ecs.Uuid,
        m: *root.Modules,
    },
};

pub fn setTarget(self: *@This(), param: SetTarget) void {
    self.cleanupTarget();
    switch (param) {
        .null => self.target = .null,
        .pos => |pos| self.target = .{ .pos = pos },
        .id_entity => |p| {
            const entity = p.m.entities.store.get(p.id);
            self.target = .{ .entity = .{
                .uuid = p.id,
                .node = .{ .cb = &targetDeinitLoopCb },
            } };
            self.target.entity.node.link(&entity.?.on_deinit_loop);
        },
    }
}

fn cleanupTarget(self: *@This()) void {
    switch (self.target) {
        .entity => |*e| e.node.unlink(),
        else => {},
    }
}
