const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

active_bodies: std.ArrayList(u32),

rand: std.Random.DefaultPrng,
id_net: u32 = undefined,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .rand = std.Random.DefaultPrng.init(395828523321213),
        .active_bodies = std.ArrayList(u32).init(allocator),
    };
}

pub fn systemInit(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try ctx.systems.world.sand_sim.loadFromPngFile(.{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } }, "land/TEST_LEVEL_WATERFALL_BIGGAP.png");

    self.id_net = try ctx.systems.net.registerSystemHandler(systems.Net.Handler.init(self, .netRecv));
}

pub fn systemDeinit(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn deinit(self: *@This()) void {
    self.active_bodies.deinit();
}

pub fn tickProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    if (self.active_bodies.items.len < 10) {
        try self.pushCrateBatch(ctx, 10);
        try self.pushChunkBatch(ctx, 10);
    }

    try self.removeSleepingBodies(ctx);
}

fn pushCrateBatch(self: *@This(), ctx: *zigra.Context, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 40,
            (self.rand.random().floatNorm(f32) + 1) * -40,
        };

        const entity_id = try prototypes.Crate.default(ctx, .{ 0, 0 }, random_vel_chunk);
        const body_id = ctx.systems.bodies.bodies.map.get(entity_id).?;

        try self.active_bodies.append(body_id);
    }
}

fn pushChunkBatch(self: *@This(), ctx: *zigra.Context, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 40,
            (self.rand.random().floatNorm(f32) + 1) * -40,
        };

        const entity_id = try prototypes.Chunk.default(ctx, .{ 0, 0 }, random_vel_chunk);
        const body_id = ctx.systems.bodies.bodies.map.get(entity_id).?;

        try self.active_bodies.append(body_id);
    }
}

fn removeSleepingBodies(self: *@This(), ctx: *zigra.Context) !void {
    const stack_capacity = 128;
    const IndexType = usize;

    var stack_fallback = std.heap.stackFallback(stack_capacity * @sizeOf(IndexType), self.allocator);
    var to_remove = std.ArrayList(IndexType).initCapacity(stack_fallback.get(), stack_capacity) catch unreachable;
    defer to_remove.deinit();

    for (self.active_bodies.items, 0..) |id, i| {
        const body = ctx.systems.bodies.bodies.getById(id);

        switch (body.*) {
            else => @panic("Unimplemented"),
            .point => |p| if (p.sleeping) {
                ctx.systems.entities.destroyEntity(ctx, p.id_entity);
                try to_remove.append(i);
            } else {
                const transform = ctx.systems.transform.data.getById(p.id_transform);
                if (transform.pos[1] > 1000) {
                    ctx.systems.entities.destroyEntity(ctx, p.id_entity);
                    try to_remove.append(i);
                }
            },
            .rigid => |r| if (r.sleeping) {
                ctx.systems.entities.destroyEntity(ctx, r.id_entity);
                try to_remove.append(i);
            } else {
                const transform = ctx.systems.transform.data.getById(r.id_transform);
                if (transform.pos[1] > 1000) {
                    ctx.systems.entities.destroyEntity(ctx, r.id_entity);
                    try to_remove.append(i);
                }
            },
        }
    }

    var iterator = std.mem.reverseIterator(to_remove.items);
    while (iterator.next()) |i| _ = self.active_bodies.swapRemove(i);
}

pub fn netRecv(self: *@This(), ctx_base: *lifetime.ContextBase, data: []const u8) !void {
    _ = self; // autofix
    _ = data; // autofix
    const ctx = ctx_base.parent(zigra.Context);
    _ = ctx; // autofix
}
