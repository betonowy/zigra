const std = @import("std");
const utils = @import("utils");
const la = @import("la");
const tracy = @import("tracy");

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

    sleepcheck_tick: u64 = 0,
    sleepcheck_pos: @Vector(2, f32) = .{ 0, 0 },
    sleeping: bool = false,
};

pub const Rigid = struct {
    id_entity: u32 = 0,
    id_transform: u32 = 0,
    id_mesh: u32 = 0,

    sleepcheck_tick: u64 = 0,
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
    bounciness: f16 = 0.5,
    friction_dynamic: f16 = 0.2,
    friction_static: f16 = 0.3,
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

    if (try self.bodies.arr.shrinkIfOversized(4)) {
        self.bodies.map.shrinkAndFree(self.bodies.map.count() / 2);
    }

    const delay = ctx.systems.time.tickDelay();
    var view = ctx.systems.world.sand_sim.getView();
    const meshes: []Mesh = self.meshes.data;
    const transforms: []systems.Transform.Data = ctx.systems.transform.data.arr.data;

    if (self.bodies.arr.capacity < 512) {
        const trace = tracy.traceNamed(@src(), "Bodies.tickProcessBodies (ST)");
        defer trace.end();

        var iterator = self.bodies.iterator();

        while (iterator.next()) |body| {
            switch (body.*) {
                .point => |*p| try self.processBodyPoint(&view, &transforms[p.id_transform], p, delay, ctx),
                .rigid => |*r| try self.processBodyRigid(&view, &transforms[r.id_transform], r, &meshes[r.id_mesh], delay, ctx),
                else => @panic("Unimplemented"),
            }
        }

        return;
    }

    const trace = tracy.traceNamed(@src(), "Bodies.tickProcessBodies (Master)");
    defer trace.end();

    const Self = @This();

    const DispatchGroup = struct {
        self: *Self,
        delay: f32,
        view: systems.World.SandSim.LandscapeView,
        meshes: []Mesh,
        transforms: []systems.Transform.Data,
        worker_data: lifetime.PackagedTask,
        index: u32,
        range: u32,
        stride: u32,

        pub fn work(task: *@This(), base: *lifetime.ContextBase) !void {
            const work_trace = tracy.traceNamed(@src(), "Bodies.tickProcessBodies (MT)");
            defer work_trace.end();

            const worker_ctx = base.parent(zigra.Context);

            var processed_bodies: u64 = 0;

            while (true) : (task.index += task.stride) {
                var iterator = task.self.bodies.boundedIterator(task.index, @min(task.index + task.range, task.self.bodies.arr.capacity));

                while (iterator.next()) |body| {
                    processed_bodies += 1;

                    switch (body.*) {
                        .point => |*p| try task.self.processBodyPoint(&task.view, &task.transforms[p.id_transform], p, task.delay, worker_ctx),
                        .rigid => |*r| try task.self.processBodyRigid(&task.view, &task.transforms[r.id_transform], r, &task.meshes[r.id_mesh], task.delay, worker_ctx),
                        else => @panic("Unimplemented"),
                    }
                }

                if (iterator.cursor >= iterator.parent.capacity) break;
            }

            var buf: [64]u8 = undefined;
            work_trace.addText(try std.fmt.bufPrint(&buf, "Processed bodies: {}", .{processed_bodies}));
        }
    };

    var dispatchGroups = try std.ArrayList(DispatchGroup).initCapacity(
        self.bodies.arr.allocator,
        ctx.base.workerGroup.workers.items.len,
    );

    defer dispatchGroups.deinit();
    try dispatchGroups.resize(dispatchGroups.capacity);

    for (dispatchGroups.items[0..], 0..) |*group, i| {
        group.self = self;
        group.delay = delay;
        group.view = view;
        group.meshes = meshes;
        group.transforms = transforms;
        group.worker_data = lifetime.PackagedTask.init(ctx_base, group, .work);
        group.range = 256;
        group.index = @as(u32, @intCast(i)) * group.range;
        group.stride = @as(u32, @intCast(dispatchGroups.items.len)) * group.range;

        if (!ctx_base.workerGroup.tryPush(&group.worker_data, 1000)) unreachable;
    }

    // {
    //     const counting_trace = tracy.traceNamed(@src(), "Bodies.tickProcessBodies (Counting)");

    //     var dispatchIterator = self.bodies.arr.iterator();
    //     var counter: u32 = 0;
    //     while (dispatchIterator.next()) |_| counter += 1;

    //     counting_trace.end();

    //     const divider = @max(1 + counter / dispatchGroups.items.len, 64);
    //     dispatchIterator.reset();
    //     counter = 0;

    //     var it_begin: u32 = 0;
    //     var it_end: u32 = 0;

    //     var current_group: u32 = 0;

    //     const dispatch_trace = tracy.traceNamed(@src(), "Bodies.tickProcessBodies (Dispatch)");
    //     defer dispatch_trace.end();

    //     while (dispatchIterator.next()) |_| : (counter += 1) {
    //         if (counter == divider) {
    //             const group = &dispatchGroups.items[current_group];

    //             it_end = dispatchIterator.cursor;
    //             defer it_begin = it_end;

    //             group.self = self;
    //             group.iterator = self.bodies.boundedIterator(it_begin, it_end);
    //             group.delay = delay;
    //             group.view = view;
    //             group.meshes = meshes;
    //             group.transforms = transforms;
    //             group.worker_data = lifetime.PackagedTask.init(ctx_base, group, .work);

    //             if (!ctx_base.workerGroup.tryPush(&group.worker_data, 1000)) unreachable;

    //             current_group += 1;
    //             counter = 0;
    //         }
    //     }

    //     if (counter != 0) {
    //         const group = &dispatchGroups.items[current_group];

    //         it_end = dispatchIterator.cursor;
    //         group.self = self;
    //         group.iterator = self.bodies.boundedIterator(it_begin, it_end);
    //         group.delay = delay;
    //         group.view = view;
    //         group.meshes = meshes;
    //         group.transforms = transforms;
    //         group.worker_data = lifetime.PackagedTask.init(ctx_base, group, .work);

    //         if (!ctx_base.workerGroup.tryPush(&group.worker_data, 1000)) unreachable;
    //     }
    // }

    ctx_base.workerGroup.flush();
}

fn processBodyPoint(
    self: *@This(),
    view: *systems.World.SandSim.LandscapeView,
    t_curr: *systems.Transform.Data,
    b_curr: *Point,
    delay: f32,
    ctx: *zigra.Context,
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
    const hit_nor = msq_result.nor orelse {
        t_next.vel = .{ 0, 0 };
        b_next.sleeping = true;
        return;
    };

    {
        const diff = t_next.pos - t_curr.pos;
        const hit_diff = hit_pos - t_curr.pos;

        const scale_ratio = la.dot(diff, hit_diff) / la.dot(diff, diff);
        if (scale_ratio > 1 or la.dot(hit_nor, t_next.vel) > 0) return;
    }

    t_next.pos = t_curr.pos;

    const hit_dot = la.dot(hit_nor, t_next.vel);

    if (hit_dot <= 0) {
        t_next.vel -= la.splat(2, 2 * hit_dot) * hit_nor;
        const speed = la.length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 + b_curr.bounce_loss * hit_dot / speed);
    } else {
        const speed = la.length(t_next.vel);
        if (speed > 0) t_next.vel *= @splat(1 - b_curr.bounce_loss);
    }

    if (la.length(b_next.sleepcheck_pos - t_curr.pos) > 2) {
        b_next.sleepcheck_pos = t_curr.pos;
        b_next.sleepcheck_tick = ctx.systems.time.tick_current;
    }

    if (b_next.sleepcheck_tick + 100 < ctx.systems.time.tick_current) {
        b_next.sleepcheck_pos = t_curr.pos;
        b_next.sleepcheck_tick = ctx.systems.time.tick_current;
        b_next.sleeping = true;
    }
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

    var has_hit = false;
    const reverse_point_traversal: bool = ctx.systems.time.tick_current & 2 == 0;

    if (reverse_point_traversal) {
        var reverse_iterator = std.mem.reverseIterator(mesh.points.constSlice());
        while (reverse_iterator.next()) |p| {
            has_hit = has_hit or try self.processBodyRigidPointCollision(view, t_curr, b_curr, &t_next, &b_next, mesh, p, delay, ctx);
        }
    } else {
        for (mesh.points.constSlice()) |p| {
            has_hit = has_hit or try self.processBodyRigidPointCollision(view, t_curr, b_curr, &t_next, &b_next, mesh, p, delay, ctx);
        }
    }

    if (!has_hit) return;

    t_next.pos = t_curr.pos;
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
) !bool {
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

    // if (ctx.systems.time.tick_current >= 1751) @breakpoint();

    const msq_result = try systems.World.Marching.intersect(view, pos_curr, pos_next + (pos_next - pos_curr) * la.splatT(2, f32, 0.01), solidCmp) orelse return false;

    const hit_pos = msq_result.pos;
    const hit_dir = msq_result.dir;
    _ = hit_dir; // autofix
    const hit_nor = msq_result.nor orelse {
        // std.log.info("tick {}: Fallback detection {} {d:.3}, curr: {d:.3} {d:.3}, next: {d:.3} {d:.3}", .{
        //     ctx.systems.time.tick_current,
        //     hit_pos,
        //     hit_dir,
        //     pos_curr,
        //     vel_curr,
        //     pos_next,
        //     vel_next,
        // });
        // @panic("elo musk");
        t_next.vel = .{ 0, 0 };
        t_next.spin = 0;
        t_next.pos = t_curr.pos;
        t_next.rot = t_curr.rot;

        // t_next.spin = 0;
        b_next.sleeping = true;
        return true;
    };

    {
        const diff = pos_next - pos_curr;
        const hit_diff = hit_pos - pos_curr;

        const scale_ratio = la.dot(diff, hit_diff) / la.dot(diff, diff);
        if (scale_ratio > 1 or la.dot(hit_nor, vel_next) > 0) return false;
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

    const offset_3d = la.zeroExtend(3, offset_curr);
    const normal_3d = la.zeroExtend(3, hit_nor);
    const dot_nor = -@abs(la.dot(hit_nor, vel_next));

    const cross_1 = la.cross(offset_3d, normal_3d) / la.splat(3, mesh.moi);
    const cross_2 = la.cross(cross_1, offset_3d);
    const cross_2d = la.truncate(2, cross_2);

    const mag_rebound_normal = -(1 + mesh.bounciness) * dot_nor / (1 / mesh.mass + la.dot(hit_nor, cross_2d));
    const impulse_rebound = la.splat(2, mag_rebound_normal) * hit_nor;

    {
        const offset_impulse_cross = la.cross(la.zeroExtend(3, offset_curr), la.zeroExtend(3, impulse_rebound));
        const vel_delta = impulse_rebound / la.splat(2, mesh.mass);
        const spin_delta = offset_impulse_cross[2] / mesh.moi;

        t_next.vel = t_curr.vel + vel_delta;
        t_next.spin = t_curr.spin + spin_delta;
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

    const offset_perp = la.perp2d(offset_curr);
    const vel_tangent = vel_next - la.splat(2, la.dot(vel_next, hit_nor)) * hit_nor;

    const impulse_friction = brk: {
        if (la.sqrLength(vel_tangent) < 1e-8) break :brk @Vector(2, f32){ 0, 0 };

        const tangent = la.normalize(vel_tangent);

        const offset_perp_dot_t = la.dot(offset_perp, tangent);
        const denominator = 1 / mesh.mass + (offset_perp_dot_t * offset_perp_dot_t) * 1 / mesh.moi;
        const jt = -la.dot(vel_next, tangent) / denominator;

        if (@abs(jt) <= mag_rebound_normal * mesh.friction_static) {
            break :brk la.splat(2, jt) * tangent;
        }

        break :brk la.splat(2, -mag_rebound_normal * mesh.friction_dynamic) * tangent;
    };

    {
        const offset_impulse_cross = la.cross(la.zeroExtend(3, offset_curr), la.zeroExtend(3, impulse_friction));
        const vel_delta = impulse_friction / la.splat(2, mesh.mass);
        const spin_delta = offset_impulse_cross[2] / mesh.moi;

        t_next.vel += vel_delta;
        t_next.spin += spin_delta;
    }

    if (la.length(b_next.sleepcheck_pos - t_curr.pos) > 2) {
        b_next.sleepcheck_pos = t_curr.pos;
        b_next.sleepcheck_tick = ctx.systems.time.tick_current;
    }

    if (b_next.sleepcheck_tick + 100 < ctx.systems.time.tick_current) {
        b_next.sleepcheck_pos = t_curr.pos;
        b_next.sleepcheck_tick = ctx.systems.time.tick_current;
        b_next.sleeping = true;
    }

    return true;
}
