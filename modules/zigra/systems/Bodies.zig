const std = @import("std");
const util = @import("utils");
const la = @import("la");
const tracy = @import("tracy");

const integrators = util.integrators;

const lifetime = @import("lifetime");
const systems = @import("../systems.zig");
const zigra = @import("../root.zig");

const max_points_per_mesh = 15;

pub const Character = struct {};

pub const RigidTerrainCollisionCb = fn (*zigra.Context, *Rigid, point: @Vector(2, f32), speed: @Vector(2, f32)) anyerror!void;
pub const PointTerrainCollisionCb = fn (*zigra.Context, *Point, point: @Vector(2, f32), speed: @Vector(2, f32)) anyerror!void;

pub const RigidCbs = struct {
    terrain_collision: ?*const RigidTerrainCollisionCb = null,
};

pub const PointCbs = struct {
    terrain_collision: ?*const PointTerrainCollisionCb = null,
};

pub const Point = struct {
    id_entity: util.ecs.Uuid = .{},
    id_transform: u32 = 0,

    weight: f16 = 1,
    drag: f16 = 0.05,
    bounce_loss: f16 = 0.1,

    sleepcheck_tick: u64 = 0,
    sleepcheck_pos: @Vector(2, f32) = .{ 0, 0 },
    sleeping: bool = false,

    cb_table: PointCbs = .{},
};

pub const Rigid = struct {
    id_entity: util.ecs.Uuid = .{},
    id_transform: u32 = 0,
    id_mesh: u32 = 0,

    sleepcheck_tick: u64 = 0,
    sleepcheck_pos: @Vector(2, f32) = .{ 0, 0 },
    sleeping: bool = false,

    cb_table: RigidCbs = .{},
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

call_arena: std.heap.ArenaAllocator,

meshes: util.IdArray(Mesh),
meshes_id_map: std.StringArrayHashMap(u32),

bodies: util.ecs.UuidContainer(Body),

gravity: f32 = 100,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .call_arena = std.heap.ArenaAllocator.init(allocator),
        .bodies = util.ecs.UuidContainer(Body).init(allocator),
        .meshes = util.IdArray(Mesh).init(allocator),
        .meshes_id_map = std.StringArrayHashMap(u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.call_arena.deinit();
    self.meshes_id_map.deinit();
    self.bodies.deinit();
    self.meshes.deinit();
}

pub fn createId(self: *@This(), comp: Body, uuid: util.ecs.Uuid) !u32 {
    return self.bodies.tryPut(uuid, comp);
}

pub fn destroyByEntityUuid(self: *@This(), uuid: util.ecs.Uuid) void {
    self.bodies.remove(uuid) catch {};
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
    defer _ = self.call_arena.reset(.retain_capacity);

    const ctx = ctx_base.parent(zigra.Context);

    if (try self.bodies.arr.shrinkIfOversized(4)) {
        self.bodies.map.shrinkAndFree(self.bodies.map.count() / 2);
    }

    const delay = ctx.systems.time.tickDelay();
    const view = ctx.systems.world.sand_sim.getView();
    const meshes: []Mesh = self.meshes.data;
    const transforms: []systems.Transform.Data = ctx.systems.transform.data.arr.data;

    const Self = @This();

    const TaskCtx = struct {
        self: *Self,
        delay: f32,
        view: systems.World.SandSim.LandscapeView,
        meshes: []Mesh,
        transforms: []systems.Transform.Data,
        index: *std.atomic.Value(u32),
        range: u32,

        pub fn work(task: *@This(), base: *lifetime.ContextBase) void {
            const work_trace = tracy.traceNamed(@src(), "tickProcessBodies (MT)");
            defer work_trace.end();

            const worker_ctx = base.parent(zigra.Context);
            var processed_bodies: u64 = 0;

            while (true) {
                const index = task.index.fetchAdd(task.range, .acq_rel);

                var iterator = task.self.bodies.boundedIterator(index, @min(
                    index + task.range,
                    task.self.bodies.arr.capacity,
                ));

                while (iterator.next()) |body| {
                    processed_bodies += 1;

                    switch (body.*) {
                        .point => |*point| task.self.processBodyPoint(
                            &task.view,
                            &task.transforms[point.id_transform],
                            point,
                            task.delay,
                            worker_ctx,
                        ) catch |e| util.tried.panic(e, @errorReturnTrace()),

                        .rigid => |*rigid| task.self.processBodyRigid(
                            &task.view,
                            &task.transforms[rigid.id_transform],
                            rigid,
                            &task.meshes[rigid.id_mesh],
                            task.delay,
                            worker_ctx,
                        ) catch |e| util.tried.panic(e, @errorReturnTrace()),

                        else => @panic("Unimplemented"),
                    }
                }

                if (iterator.cursor >= iterator.parent.capacity) break;
            }

            var buf: [64]u8 = undefined;
            work_trace.addText(std.fmt.bufPrint(&buf, "Processed bodies {}", .{processed_bodies}) catch unreachable);
        }
    };

    // const task_count = brk: {
    //     const max_tasks = ctx.base.thread_pool.threads.len;
    //     const key_count = self.bodies.arr.keys.len;
    //     if (key_count == 0) return;
    //     break :brk @min(max_tasks, @max(key_count / 2, 1));
    // };

    const task_count = 1;

    const dispatch_ctx = try self.call_arena.allocator().allocWithOptions(TaskCtx, task_count, std.atomic.cache_line, null);
    var dispatch_index = std.atomic.Value(u32).init(0);

    for (dispatch_ctx) |*group| group.* = .{
        .self = self,
        .delay = delay,
        .view = view,
        .meshes = meshes,
        .transforms = transforms,
        .index = &dispatch_index,
        .range = 64,
    };

    if (task_count == 1) {
        dispatch_ctx[0].work(ctx_base);
        return;
    }

    var wg = std.Thread.WaitGroup{};
    for (dispatch_ctx) |*group| ctx_base.thread_pool.spawnWg(&wg, TaskCtx.work, .{ group, ctx_base });
    ctx_base.thread_pool.waitAndWork(&wg);
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

    const msq_result = try view.intersect(t_curr.pos, t_next.pos, solidCmp) orelse return;

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

    if (b_next.cb_table.terrain_collision) |cb| try cb(ctx, &b_next, t_next.pos, t_next.vel);
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
        t_next.rot = la.normalizedRotation(t_next.rot);
        t_curr.* = t_next;
        b_curr.* = b_next;
    }

    const center_cell = try view.get(@intFromFloat(t_next.pos));

    const gravity = switch (center_cell.type) {
        .liquid => -self.gravity * 0.25,
        else => self.gravity,
    };

    const drag = switch (center_cell.type) {
        .liquid => mesh.drag * 100,
        else => mesh.drag,
    };

    const acc = @Vector(2, f32){ 0, gravity } - la.splat(2, drag) * t_curr.vel;
    t_next.pos = integrators.verletPosition(@Vector(2, f32), t_curr.pos, t_curr.vel, acc, delay);
    t_next.vel = integrators.verletVelocity(@Vector(2, f32), t_curr.vel, acc, delay);
    const omega = -drag * t_curr.spin;
    t_next.spin = integrators.verletVelocity(f32, t_next.spin, omega, delay);
    t_next.rot += t_next.spin * delay;

    var has_hit = false;

    for (mesh.points.constSlice()) |p| {
        has_hit = has_hit or try self.processBodyRigidPointCollision(view, t_curr, b_curr, &t_next, &b_next, mesh, p, delay, ctx, center_cell.type == .liquid);
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
    is_underwater: bool,
) !bool {
    _ = self; // autofix
    _ = b_curr; // autofix
    _ = delay; // autofix

    const offset_curr_init = la.rotate2d(point, t_curr.rot);
    const offset_next_init = la.rotate2d(point, t_next.rot);

    const vel_rel_next_init = la.perp2d(offset_next_init) * la.splat(2, t_next.spin);

    const pos_curr_init = offset_curr_init + t_curr.pos;
    const pos_next_init = offset_next_init + t_next.pos;
    const pos_next_init_adjusted = pos_next_init + (pos_next_init - pos_curr_init) * la.splatT(2, f32, 0.01);

    const vel_next_init = vel_rel_next_init + t_next.vel;
    const msq_result = try view.intersect(pos_curr_init, pos_next_init_adjusted, solidCmp) orelse {
        if (!is_underwater) return false;

        if (b_next.sleepcheck_tick == 0) {
            b_next.sleepcheck_tick = ctx.systems.time.tick_current;
            return false;
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

        return false;
    };

    const hit_pos = msq_result.pos;
    const hit_nor = msq_result.nor orelse brk: {
        if (try view.normalKernel3(hit_pos, solidCmp)) |normal| break :brk normal;
        if (try view.normalKernel5(hit_pos, solidCmp)) |normal| break :brk normal;

        t_next.vel = .{ 0, 0 };
        t_next.spin = 0;
        t_next.pos = t_curr.pos;
        t_next.rot = t_curr.rot;
        return true;
    };

    {
        const diff = pos_next_init - pos_curr_init;
        const hit_diff = hit_pos - pos_curr_init;

        const scale_ratio = la.dot(diff, hit_diff) / la.dot(diff, diff);
        if (scale_ratio > 1 or la.dot(hit_nor, vel_next_init) > 0) return false;
    }

    const mag_rebound_normal = brk: {
        const offset_3d = la.zeroExtend(3, offset_curr_init);
        const normal_3d = la.zeroExtend(3, hit_nor);
        const dot_nor = -@abs(la.dot(hit_nor, vel_next_init));

        const cross_1 = la.cross(offset_3d, normal_3d) / la.splat(3, mesh.moi);
        const cross_2 = la.cross(cross_1, offset_3d);
        const cross_2d = la.truncate(2, cross_2);

        const mag_rebound_normal =
            -(1 + mesh.bounciness) * dot_nor /
            (1 / mesh.mass + la.dot(hit_nor, cross_2d));

        const impulse_rebound = la.splat(2, mag_rebound_normal) * hit_nor;

        const offset_impulse_cross = la.cross(
            la.zeroExtend(3, offset_curr_init),
            la.zeroExtend(3, impulse_rebound),
        );

        const vel_delta = impulse_rebound / la.splat(2, mesh.mass);
        const spin_delta = offset_impulse_cross[2] / mesh.moi;

        t_next.vel = t_curr.vel + vel_delta;
        t_next.spin = t_curr.spin + spin_delta;

        break :brk mag_rebound_normal;
    };

    const impulse_friction = brk: {
        const vel_rel_next_post_rebound = la.perp2d(offset_next_init) * la.splat(2, t_next.spin);
        const vel_next_post_rebound = vel_rel_next_post_rebound + t_next.vel;

        const offset_perp = la.perp2d(offset_curr_init);
        const vel_tangent = vel_next_post_rebound - la.splat(2, la.dot(vel_next_post_rebound, hit_nor)) * hit_nor;

        if (la.sqrLength(vel_tangent) < 1e-8) break :brk @Vector(2, f32){ 0, 0 };

        const tangent = la.normalize(vel_tangent);

        const offset_perp_dot_t = la.dot(offset_perp, tangent);
        const denominator = 1 / mesh.mass + (offset_perp_dot_t * offset_perp_dot_t) * 1 / mesh.moi;
        const jt = -la.dot(vel_next_post_rebound, tangent) / denominator;

        if (@abs(jt) <= mag_rebound_normal * mesh.friction_static) {
            break :brk la.splat(2, jt) * tangent;
        }

        break :brk la.splat(2, -mag_rebound_normal * mesh.friction_dynamic) * tangent;
    };

    {
        const offset_impulse_cross = la.cross(
            la.zeroExtend(3, offset_curr_init),
            la.zeroExtend(3, impulse_friction),
        );

        const vel_delta = impulse_friction / la.splat(2, mesh.mass);
        const spin_delta = offset_impulse_cross[2] / mesh.moi;

        t_next.vel += vel_delta;
        t_next.spin += spin_delta;
    }

    if (b_next.sleepcheck_tick == 0) {
        b_next.sleepcheck_tick = ctx.systems.time.tick_current;
        return false;
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

    if (b_next.cb_table.terrain_collision) |cb| try cb(ctx, b_next, pos_next_init, vel_next_init);

    return true;
}
