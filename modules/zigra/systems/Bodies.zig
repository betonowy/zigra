const std = @import("std");
const utils = @import("utils");
const la = @import("la");
const integrators = utils.integrators;

const lifetime = @import("lifetime");
const systems = @import("../systems.zig");
const zigra = @import("../root.zig");

const max_points_per_mesh = 15;

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
    id_mesh: u32 = 0,

    sleepcheck_pos: @Vector(2, f32) = .{ 0, 0 },
    sleeping: bool = false,
};

pub const Body = union(enum) {
    point: Point,
    rigid: Rigid,
    character: Character,
};

pub const Mesh = struct {
    points: std.BoundedArray(@Vector(2, f16), max_points_per_mesh) = .{},
    moi: f16 = 1,
    mass: f16 = 1,
    drag: f16 = 0.05,
    bounce_loss: f16 = 0.5,
};

meshes: utils.IdArray(Mesh),
meshes_id_map: std.StringArrayHashMap(u32),

bodies: utils.ExtIdMappedIdArray(Body),

gravity: f32 = 100,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .bodies = utils.ExtIdMappedIdArray(Body).init(allocator),
        .meshes = utils.IdArray(Mesh).init(allocator),
        .meshes_id_map = std.StringArrayHashMap(u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.meshes_id_map.deinit();
    self.bodies.deinit();
    self.meshes.deinit();
}

pub fn createId(self: *@This(), comp: Body, entity_id: u32) !u32 {
    return self.bodies.put(entity_id, comp);
}

pub fn destroyByEntityId(self: *@This(), id: u32) void {
    self.bodies.remove(id);
}

pub fn getMeshIdForPath(self: *@This(), path: []const u8) !u32 {
    const res = try self.meshes_id_map.getOrPut(path);
    if (!res.found_existing) res.value_ptr.* = try self.meshes.put(undefined);
    return res.value_ptr.*;
}

pub fn getMeshById(self: *@This(), id: u32) *Mesh {
    return self.meshes.at(id);
}

fn solidCmp(cell: systems.World.SandSim.Cell) f32 {
    return if (cell.type == .solid) 1 else 0;
}

pub fn tickProcessBodies(self: *@This(), ctx_base: *lifetime.ContextBase) !void {
    const ctx = ctx_base.parent(zigra.Context);

    const delay = ctx.systems.time.tickDelay();
    var view = ctx.systems.world.sand_sim.getView();
    const meshes: []Mesh = self.meshes.data;
    const transforms: []systems.Transform.Data = ctx.systems.transform.data.arr.data;

    var iterator = self.bodies.iterator();

    while (iterator.next()) |body| {
        switch (body.*) {
            .point => |*p| try self.processBodyPoint(&view, &transforms[p.id_transform], p, delay),
            .rigid => |*r| try self.processBodyRigid(&view, &transforms[r.id_transform], r, &meshes[r.id_mesh], delay, ctx),
            else => @panic("Unimplemented"),
        }
    }
}

fn processBodyPoint(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Data,
    b_curr: *Point,
    delay: f32,
) !void {
    if (b_curr.sleeping) return;

    var t_next = t_curr.*;
    var b_next = b_curr.*;

    const acc = @Vector(2, f32){ 0, self.gravity } - la.splat(2, b_curr.drag) * t_curr.vel;
    t_next.pos = integrators.verletPosition(@Vector(2, f32), t_curr.pos, t_curr.vel, acc, delay);
    t_next.vel = integrators.verletVelocity(@Vector(2, f32), t_curr.vel, acc, delay);

    defer {
        t_curr.* = t_next;
        b_curr.* = b_next;
    }

    const msq_result = try systems.World.Marching.intersect(view, t_curr.pos, t_next.pos, solidCmp) orelse return;

    const hit_pos = msq_result.pos;
    // const hit_dir = msq_result.dir;
    const hit_nor = msq_result.nor orelse {
        t_next.vel = .{ 0, 0 };
        b_next.sleeping = true;
        return;
    };

    const diff = t_next.pos - t_curr.pos;
    const hit_diff = hit_pos - t_curr.pos;
    const scale_ratio = la.dot(diff, hit_diff) / la.dot(diff, diff);

    if (scale_ratio > 1 or la.dot(hit_nor, t_next.vel) > 0) return;

    t_next.pos = t_curr.pos;

    // if (@reduce(.Add, hit_nor * hit_dir) < 0) {
    // t_next.vel = la.mix(t_curr.vel, t_next.vel, @min(scale_ratio, 0));
    // }

    const hit_dot = la.dot(hit_nor, t_next.vel);

    if (hit_dot <= 0) {
        t_next.vel -= la.splat(2, 2 * hit_dot) * hit_nor;
        const speed = la.length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 + b_curr.bounce_loss * hit_dot / speed);
    } else {
        const speed = la.length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 - b_curr.bounce_loss);
    }

    // if (la.length(t_curr.pos - t_next.pos) < 3e-2 and hit_dot > 0 and scale_ratio == 0 and
    //     @abs(@reduce(.Add, t_next.vel * @Vector(2, f32){ hit_nor[1], -hit_nor[0] })) < 1e-3)
    // {
    //     b_next.sleeping = true;
    //     t_next.vel = .{ 0, 0 };
    // }
}

fn processBodyRigid(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Data,
    b_curr: *Rigid,
    mesh: *Mesh,
    delay: f32,
    ctx: *zigra.Context,
) !void {
    if (b_curr.sleeping) return;

    var t_next = t_curr.*;
    var b_next = b_curr.*;

    defer {
        t_curr.* = t_next;
        b_curr.* = b_next;
    }

    const acc = @Vector(2, f32){ 0, self.gravity } - la.splat(2, mesh.drag) * t_curr.vel;
    t_next.pos = integrators.verletPosition(@Vector(2, f32), t_curr.pos, t_curr.vel, acc, delay);
    t_next.vel = integrators.verletVelocity(@Vector(2, f32), t_curr.vel, acc, delay);
    t_next.rot += t_next.spin * delay;

    var point_impulses = std.BoundedArray(Impulse, max_points_per_mesh){};

    for (mesh.points.constSlice()) |p| {
        const opt_impulse = try self.processBodyRigidPointCollision(view, t_curr, b_curr, &t_next, &b_next, mesh, p, delay, ctx);
        if (opt_impulse) |impulse| try point_impulses.append(impulse);
    }

    if (point_impulses.len == 0) return;

    var impulse_avg = @Vector(2, f32){ 0, 0 };
    var point_avg = @Vector(2, f32){ 0, 0 };

    for (point_impulses.constSlice()) |v| {
        impulse_avg += v.impulse;
        point_avg += v.offset;
    }

    const ratio = @sqrt(@as(f32, @floatFromInt(point_impulses.len)));

    impulse_avg /= @splat(ratio);
    point_avg /= @splat(ratio);

    const offset_impulse_cross = la.cross(la.zeroExtend(3, point_avg), la.zeroExtend(3, impulse_avg));
    const vel_delta = impulse_avg / la.splat(2, mesh.mass);
    const spin_delta = offset_impulse_cross[2] / mesh.moi;

    t_next.pos = t_curr.pos;
    t_next.vel = t_curr.vel + vel_delta;
    t_next.spin = t_curr.spin + spin_delta;
    t_next.rot = t_curr.rot;
}

const Impulse = struct {
    offset: @Vector(2, f32),
    impulse: @Vector(2, f32),
};

fn processBodyRigidPointCollision(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Data,
    b_curr: *Rigid,
    t_next: *systems.Transform.Data,
    b_next: *Rigid,
    mesh: *Mesh,
    point: @Vector(2, f32),
    delay: f32,
    ctx: *zigra.Context,
) !?Impulse {
    _ = b_next; // autofix
    _ = self; // autofix
    _ = b_curr; // autofix
    _ = delay; // autofix

    var offset_curr = la.rotate2d(point, t_curr.rot);
    var offset_next = la.rotate2d(point, t_next.rot);

    var vel_rel_curr = la.perp2d(offset_curr) * la.splat(2, t_curr.spin);
    var vel_rel_next = la.perp2d(offset_next) * la.splat(2, t_next.spin);

    var pos_curr = offset_curr + t_curr.pos;
    var pos_next = offset_next + t_next.pos;

    var vel_curr = vel_rel_curr + t_curr.vel;
    var vel_next = vel_rel_next + t_next.vel;

    const msq_result = try systems.World.Marching.intersect(view, pos_curr, pos_next, solidCmp) orelse return null;

    const hit_pos = msq_result.pos;
    const hit_dir = msq_result.dir;
    const hit_nor = msq_result.nor orelse {
        std.log.info("tick {}: Woops! sinking? {} {d:.3}, curr: {d:.3} {d:.3}, next: {d:.3} {d:.3}", .{
            ctx.systems.time.tick_current,
            hit_pos,
            hit_dir,
            pos_curr,
            vel_curr,
            pos_next,
            vel_next,
        });
        // @panic("elo musk");
        // t_next.vel = .{ 0, 0 };
        // t_next.spin = 0;
        // b_next.sleeping = true;
        return null;
    };

    {
        const diff = pos_next - pos_curr;
        const hit_diff = hit_pos - pos_curr;

        const scale_ratio = la.dot(diff, hit_diff) / la.dot(diff, diff);
        if (scale_ratio > 1 or la.dot(hit_nor, vel_next) > 0) return null;
    }

    {
        offset_curr = la.rotate2d(point, t_curr.rot);
        offset_next = la.rotate2d(point, t_next.rot);

        vel_rel_curr = la.perp2d(offset_curr) * la.splat(2, t_curr.spin);
        vel_rel_next = la.perp2d(offset_next) * la.splat(2, t_next.spin);

        pos_curr = offset_curr + t_curr.pos;
        pos_next = offset_next + t_next.pos;

        vel_curr = vel_rel_curr + t_curr.vel;
        vel_next = vel_rel_next + t_next.vel;
    }

    const offset_3d = la.zeroExtend(3, offset_next);
    const normal_3d = la.zeroExtend(3, hit_nor);
    const dot_nor = -@abs(la.dot(hit_nor, vel_next));

    const cross_1 = la.cross(offset_3d, normal_3d) / la.splat(3, mesh.moi);
    const cross_2 = la.cross(cross_1, offset_3d);
    const cross_2d = la.truncate(2, cross_2);

    const mag_rebound_normal = -(2 - mesh.bounce_loss) * dot_nor / (1 / mesh.mass + la.dot(hit_nor, cross_2d));
    const rebound_nor = la.splat(2, mag_rebound_normal) * hit_nor;

    // const hit_tangent = @Vector(2, f32){ -hit_nor[1], hit_nor[0] };
    // const dot_tangent = la.dot(hit_tangent, vel_next);

    // const mag_friction_tangent = -@max(mag_rebound_normal * mesh.bounce_loss * 0.5, 0);
    // const max_impulse_tangent = @abs(dot_tangent);

    // const tan_sign: f32 = if (dot_tangent < 0) -1 else 1;
    // const impulse_tan = @as(@Vector(2, f32), @splat(@min(mag_friction_tangent, max_impulse_tangent) * tan_sign)) * hit_tangent;

    // const impulse = rebound_nor + impulse_tan;

    // const offset_impulse_cross = cross(offset_3d, @Vector(3, f32){ impulse[0], impulse[1], 0 });
    // const vel_delta = impulse / @as(@Vector(2, f32), @splat(mesh.mass));
    // const spin_delta = offset_impulse_cross[2] / mesh.moi;

    // t_next.vel += vel_delta;
    // t_next.spin += spin_delta;

    return .{ .offset = offset_next, .impulse = rebound_nor };
}
