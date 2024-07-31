const std = @import("std");
const utils = @import("utils");
const la = @import("la");
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
    points: std.BoundedArray(@Vector(2, f16), 15) = .{},
    moi: f16 = 1,
    mass: f16 = 1,
    drag: f16 = 0.05,
    bounce_loss: f16 = 0.1,
};

meshes: utils.IdStore(Mesh),
meshes_id_map: std.StringArrayHashMap(u32),

bodies: utils.IdStore(Body),
entity_id_map: std.AutoHashMap(u32, u32),

gravity: f32 = 100,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .bodies = utils.IdStore(Body).init(allocator),
        .entity_id_map = std.AutoHashMap(u32, u32).init(allocator),
        .meshes = utils.IdStore(Mesh).init(allocator),
        .meshes_id_map = std.StringArrayHashMap(u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.entity_id_map.deinit();
    self.meshes_id_map.deinit();
    self.bodies.deinit();
    self.meshes.deinit();
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

pub fn getMeshIdForPath(self: *@This(), path: []const u8) !u32 {
    const res = try self.meshes_id_map.getOrPut(path);
    if (!res.found_existing) res.value_ptr.* = try self.meshes.createId();
    return res.value_ptr.*;
}

pub fn getMeshById(self: *@This(), id: u32) !*Mesh {
    return &self.meshes.slice().items(.payload)[id];
}

fn solidCmp(cell: systems.World.SandSim.Cell) f32 {
    return if (cell.type == .solid) 1 else 0;
}

pub fn tickProcessBodies(self: *@This(), ctx_base: *lifetime.ContextBase) !void {
    const ctx = ctx_base.parent(zigra.Context);

    const delay = ctx.systems.time.tickDelay();
    var view = ctx.systems.world.sand_sim.getView();
    const meshes: []Mesh = self.meshes.slice().items(.payload);
    const transforms: []systems.Transform.Transform =
        ctx.systems.transform.transforms.slice().items(.payload);

    var iterator = self.bodies.iterator();

    while (iterator.next()) |fields| {
        switch (fields.payload.*) {
            .point => |*p| try self.processBodyPoint(&view, &transforms[p.id_transform], p, delay),
            .rigid => |*r| try self.processBodyRigid(&view, &transforms[r.id_transform], r, &meshes[r.id_mesh], delay, ctx),
            else => @panic("Unimplemented"),
        }
    }
}

fn processBodyPoint(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Transform,
    b_curr: *Point,
    delay: f32,
) !void {
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
    const scale_ratio = @reduce(.Add, diff * hit_diff) / @reduce(.Add, diff * diff);

    if (scale_ratio > 1 or @reduce(.Add, hit_nor * t_next.vel) > 0) return;

    t_next.pos = hit_pos;

    if (@reduce(.Add, hit_nor * hit_dir) < 0) {
        t_next.vel = la.mix(t_curr.vel, t_next.vel, @min(scale_ratio, 0));
    }

    const hit_dot = @reduce(.Add, hit_nor * t_next.vel);

    if (hit_dot <= 0) {
        t_next.vel -= @as(@Vector(2, f32), @splat(2 * hit_dot)) * hit_nor;
        const speed = la.length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 + b_curr.bounce_loss * hit_dot / speed);
    } else {
        const speed = la.length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 - b_curr.bounce_loss);
    }

    if (la.length(t_curr.pos - t_next.pos) < 3e-2 and hit_dot > 0 and scale_ratio == 0 and
        @abs(@reduce(.Add, t_next.vel * @Vector(2, f32){ hit_nor[1], -hit_nor[0] })) < 1e-3)
    {
        b_next.sleeping = true;
        t_next.vel = .{ 0, 0 };
    }
}

fn processBodyRigid(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Transform,
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

    const acc = @Vector(2, f32){ 0, self.gravity } - @as(@Vector(2, f32), @splat(mesh.drag)) * t_curr.vel;
    t_next.pos = integrators.verletPosition(@Vector(2, f32), t_curr.pos, t_curr.vel, acc, delay);
    t_next.vel = integrators.verletVelocity(@Vector(2, f32), t_curr.vel, acc, delay);
    t_next.rot += t_next.spin * delay;

    var collision_deltas = CollisionDeltas{};

    for (mesh.points.constSlice()) |p| {
        collision_deltas.add(try self.processBodyRigidPointCollision(view, t_curr, b_curr, &t_next, &b_next, mesh, p, delay, ctx));
    }

    // README PLEASE
    // The reason dividing is working weird is because we're collapsing impulses into points early
    // Should sum impulses, divide them, and then apply to velocity and spin

    if (!collision_deltas.isNull()) {
        t_next.pos = t_curr.pos;
        t_next.vel = t_curr.vel + collision_deltas.vel / collision_deltas.denominatorV2();
        t_next.spin = t_curr.spin + collision_deltas.spin / collision_deltas.denominator();
        t_next.rot = t_curr.rot;
    } else {}
}

fn rotate2d(v: @Vector(2, f32), angle: f32) @Vector(2, f32) {
    const cos = @cos(angle);
    const sin = @sin(angle);

    return .{
        v[0] * cos - v[1] * sin,
        v[0] * sin + v[1] * cos,
    };
}

fn clamp(v: anytype, a: anytype, b: anytype) @TypeOf(v, a, b) {
    return @min(b, @max(a, v));
}

fn cross(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{
        a[1] * b[2] - b[1] * a[2],
        a[2] * b[0] - b[2] * a[0],
        a[0] * b[1] - b[0] * a[1],
    };
}

const CollisionDeltas = struct {
    vel: @Vector(2, f32) = .{ 0, 0 },
    spin: f32 = 0,
    sum: usize = 0,

    pub fn add(self: *@This(), other_opt: ?@This()) void {
        if (other_opt) |other| {
            self.vel += other.vel;
            self.spin += other.spin;
            self.sum += 1;
        }
    }

    pub fn denominatorV2(self: @This()) @Vector(2, f32) {
        return @splat(self.denominator());
    }

    pub fn denominator(self: @This()) f32 {
        return @floatFromInt(self.sum);
    }

    pub fn isNull(self: @This()) bool {
        return self.vel[0] == 0 and self.vel[1] == 0 and self.spin == 0;
    }
};

fn processBodyRigidPointCollision(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Transform,
    b_curr: *Rigid,
    t_next: *systems.Transform.Transform,
    b_next: *Rigid,
    mesh: *Mesh,
    point: @Vector(2, f32),
    delay: f32,
    ctx: *zigra.Context,
) !?CollisionDeltas {
    _ = ctx; // autofix
    _ = b_next; // autofix
    _ = self; // autofix
    _ = b_curr; // autofix
    _ = delay; // autofix

    var offset_curr = rotate2d(point, t_curr.rot);
    var offset_next = rotate2d(point, t_next.rot);

    var vel_rel_curr = @Vector(2, f32){ -offset_curr[1], offset_curr[0] } * @as(@Vector(2, f32), @splat(t_curr.spin));
    var vel_rel_next = @Vector(2, f32){ -offset_next[1], offset_next[0] } * @as(@Vector(2, f32), @splat(t_next.spin));

    var pos_curr = offset_curr + t_curr.pos;
    var pos_next = offset_next + t_next.pos;

    var vel_curr = vel_rel_curr + t_curr.vel;
    var vel_next = vel_rel_next + t_next.vel;

    // if (ctx.systems.time.tick_current == 15) @breakpoint();

    // std.log.info("about to do intersect", .{});

    const msq_result = try systems.World.Marching.intersect(view, pos_curr, pos_next, solidCmp) orelse return null;

    const hit_pos = msq_result.pos;
    const hit_dir = msq_result.dir;
    _ = hit_dir; // autofix
    const hit_nor = msq_result.nor orelse {
        // std.log.info("tick {}: Woops! sinking? {} {d:.3}, curr: {d:.3} {d:.3}, next: {d:.3} {d:.3}", .{
        //     ctx.systems.time.tick_current,
        //     hit_pos,
        //     hit_dir,
        //     pos_curr,
        //     vel_curr,
        //     pos_next,
        //     vel_next,
        // });
        // @panic("elo musk");
        // t_next.vel = .{ 0, 0 };
        // t_next.spin = 0;
        // b_next.sleeping = true;
        return null;
    };

    // std.log.info("tick {}: Bounce: {d:.3} {d:.3} {d:.3}, curr: {d:.3} {d:.3}, next: {d:.3} {d:.3}", .{
    //     ctx.systems.time.tick_current,
    //     hit_pos,
    //     hit_dir,
    //     hit_nor,
    //     pos_curr,
    //     vel_curr,
    //     pos_next,
    //     vel_next,
    // });

    {
        const diff = pos_next - pos_curr;
        const hit_diff = hit_pos - pos_curr;

        const scale_ratio = @reduce(.Add, diff * hit_diff) / @reduce(.Add, diff * diff);
        if (scale_ratio > 1 or @reduce(.Add, hit_nor * vel_next) > 0) return null;
    }

    // if (@reduce(.Add, hit_nor * hit_dir) < 0) {
    //     t_next.vel = la.mix(t_curr.vel, t_next.vel, clamp(scale_ratio, 0, 1));
    //     t_next.pos = la.mix(t_curr.pos, t_next.pos, clamp(scale_ratio, 0, 1));
    //     t_next.rot = la.mix(t_curr.rot, t_next.rot, clamp(scale_ratio, 0, 1));
    // }

    // t_next.pos += hit_pos - pos_next + hit_nor * @as(@Vector(2, f32), @splat(0));

    {
        offset_curr = rotate2d(point, t_curr.rot);
        offset_next = rotate2d(point, t_next.rot);

        vel_rel_curr = @Vector(2, f32){ -offset_curr[1], offset_curr[0] } * @as(@Vector(2, f32), @splat(t_curr.spin));
        vel_rel_next = @Vector(2, f32){ -offset_next[1], offset_next[0] } * @as(@Vector(2, f32), @splat(t_next.spin));

        pos_curr = offset_curr + t_curr.pos;
        pos_next = offset_next + t_next.pos;

        vel_curr = vel_rel_curr + t_curr.vel;
        vel_next = vel_rel_next + t_next.vel;
    }

    // const hit_tangent = @Vector(2, f32){ -hit_nor[1], hit_nor[0] };
    const dot_nor = -@abs(la.dot(hit_nor, vel_next));
    // const dot_tangent = la.dot(hit_tangent, vel_next);

    const offset_3d = @Vector(3, f32){ offset_next[0], offset_next[1], 0 };
    const normal_3d = @Vector(3, f32){ hit_nor[0], hit_nor[1], 0 };

    const impulse = brk: {
        const cross_1 = cross(offset_3d, normal_3d) / @as(@Vector(3, f32), @splat(mesh.moi));
        const cross_2 = cross(cross_1, offset_3d);
        const cross_2d = @Vector(2, f32){ cross_2[0], cross_2[1] };

        const mag_rebound_normal = -(2 - mesh.bounce_loss) * dot_nor / (1 / mesh.mass + @reduce(.Add, hit_nor * cross_2d)) + @as(f32, 0);
        // const mag_friction_tangent = -@max(mag_rebound_normal * mesh.bounce_loss * 0.5, 0);
        // const max_impulse_tangent = @abs(dot_tangent);

        const rebound_nor = @as(@Vector(2, f32), @splat(mag_rebound_normal)) * hit_nor;
        // const tan_sign: f32 = if (dot_tangent < 0) -1 else 1;
        // const impulse_tan = @as(@Vector(2, f32), @splat(@min(mag_friction_tangent, max_impulse_tangent) * tan_sign)) * hit_tangent;

        break :brk rebound_nor;
    };

    const offset_impulse_cross = cross(offset_3d, @Vector(3, f32){ impulse[0], impulse[1], 0 });
    const vel_delta = impulse / @as(@Vector(2, f32), @splat(mesh.mass));
    const spin_delta = offset_impulse_cross[2] / mesh.moi;

    return .{
        .vel = vel_delta,
        .spin = spin_delta,
    };

    // t_next.vel += vel_delta;
    // t_next.spin += spin_delta;

    // return null;
}

fn processBodyRigidPointSinking(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Transform,
    b_curr: *Rigid,
    t_next: *systems.Transform.Transform,
    b_next: *Rigid,
    mesh: *Mesh,
    point: @Vector(2, f32),
    delay: f32,
) !void {
    _ = self; // autofix
    _ = view; // autofix
    _ = t_curr; // autofix
    _ = b_curr; // autofix
    _ = t_next; // autofix
    _ = b_next; // autofix
    _ = mesh; // autofix
    _ = point; // autofix
    _ = delay; // autofix
}
