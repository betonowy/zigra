const std = @import("std");
const utils = @import("utils");
const integrators = utils.integrators;

const lifetime = @import("lifetime");
const systems = @import("../systems.zig");
const zigra = @import("../root.zig");

pub const Character = struct {};

pub const Point = struct {
    id_entity: u32 = 0,
    id_transform: u32 = 0,

    weight: f16 = 1,
    drag: f16 = 0.05,
    bounce_loss: f16 = 0.1,

    sleeping: bool = false,
};

pub const Rigid = struct {
    id_entity: u32 = 0,
    id_transform: u32 = 0,
    id_body_mesh: u32 = 0,

    weight: f16 = 1,
    drag: f16 = 0.05,
    bounce_loss: f16 = 0.1,

    sleeping: bool = false,
};

pub const Body = union(enum) {
    point: Point,
    rigid: Rigid,
    character: Character,
};

bodies: utils.IdStore(Body),
entity_id_map: std.AutoHashMap(u32, u32),

gravity: f32 = 100,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .bodies = utils.IdStore(Body).init(allocator),
        .entity_id_map = std.AutoHashMap(u32, u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.entity_id_map.deinit();
    self.bodies.deinit();
}

pub fn createId(self: *@This(), comp: Body, entity_id: u32) !u32 {
    const internal_id = try self.bodies.push(comp);
    try self.entity_id_map.put(entity_id, internal_id);
    return internal_id;
}

pub fn destroyByEntityId(self: *@This(), id: u32) void {
    const kv = self.entity_id_map.fetchRemove(id) orelse @panic("Entity id not found");
    self.bodies.destroyId(kv.value) catch @panic("Transform id not found");
}

fn solidCmp(cell: systems.World.SandSim.Cell) f32 {
    return if (cell.type == .solid) 1 else 0;
}

pub fn tickProcessBodies(self: *@This(), ctx_base: *lifetime.ContextBase) !void {
    const ctx = ctx_base.parent(zigra.Context);

    var landscape_view = ctx.systems.world.sand_sim.getView();

    const transforms: []systems.Transform.Transform =
        ctx.systems.transform.transforms.slice().items(.payload);

    const delay = ctx.systems.time.tickDelay();

    var iterator = self.bodies.iterator();

    while (iterator.next()) |fields| {
        switch (fields.payload.*) {
            .point => |*p| try self.processBodyPoint(&landscape_view, &transforms[p.id_transform], p, delay),
            else => {},
        }
    }
}

fn processBodyPoint(self: *@This(), view: *systems.World.SandSim.LandscapeView, t_curr: *systems.Transform.Transform, b_curr: *Point, delay: f32) !void {
    if (b_curr.sleeping) return;

    var t_next = t_curr.*;
    var b_next = b_curr.*;

    const acc = @Vector(2, f32){ 0, self.gravity } - @as(@Vector(2, f32), @splat(b_curr.drag)) * t_curr.vel;
    t_next.pos = integrators.verletPosition(@Vector(2, f32), t_curr.pos, t_curr.vel, acc, delay);
    t_next.vel = integrators.verletVelocity(@Vector(2, f32), t_curr.vel, acc, delay);

    defer {
        t_curr.* = t_next;
        b_curr.* = b_next;
    }

    const msq_result = try systems.World.Marching.intersect(view, t_curr.pos, t_next.pos, solidCmp) orelse return;

    const hit_pos = msq_result.pos;
    const hit_dir = msq_result.dir;
    const hit_nor = msq_result.nor orelse {
        t_next.vel = .{ 0, 0 };
        b_next.sleeping = true;
        return;
    };

    const diff = t_next.pos - t_curr.pos;
    const hit_diff = hit_pos - t_curr.pos;
    const scale_ratio = dot(diff, hit_diff) / dot(diff, diff);

    if (scale_ratio > 1 or dot(hit_nor, t_next.vel) > 0) return;

    t_next.pos = hit_pos;

    if (dot(hit_nor, hit_dir) < 0) {
        t_next.vel = mix(t_curr.vel, t_next.vel, @min(scale_ratio, 0));
    }

    const hit_dot = dot(hit_nor, t_next.vel);

    if (hit_dot <= 0) {
        t_next.vel -= @as(@Vector(2, f32), @splat(2 * hit_dot)) * hit_nor;
        const speed = length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 + b_curr.bounce_loss * hit_dot / speed);
    } else {
        const speed = length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 - b_curr.bounce_loss);
    }

    if (length(t_curr.pos - t_next.pos) < 3e-2 and
        hit_dot > 0 and scale_ratio == 0 and @abs(dot(t_next.vel, .{ hit_nor[1], -hit_nor[0] })) < 1e-3)
    {
        b_next.sleeping = true;
        t_next.vel = .{ 0, 0 };
    }
}

fn mix(a: @Vector(2, f32), b: @Vector(2, f32), r: f32) @Vector(2, f32) {
    return a * @as(@TypeOf(a), @splat(1 - r)) + b * @as(@TypeOf(b), @splat(r));
}

fn dot(a: @Vector(2, f32), b: @Vector(2, f32)) f32 {
    return @reduce(.Add, a * b);
}

fn length(a: @Vector(2, f32)) f32 {
    return @sqrt(dot(a, a));
}
