const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

active_entities: std.ArrayList(u32),

rand: std.Random.DefaultPrng,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .rand = std.Random.DefaultPrng.init(395828523321213),
        .active_entities = std.ArrayList(u32).init(allocator),
    };
}

pub fn systemInit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try ctx.systems.world.sand_sim.loadFromPngFile(.{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } }, "land/TEST_LEVEL_WATERFALL_BIGGAP.png");
}

pub fn systemDeinit(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn deinit(self: *@This()) void {
    self.active_entities.deinit();
}

pub fn tickProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    if (self.active_entities.items.len < 10000) {
        try self.pushCrateBatch(ctx, 100);
        try self.pushChunkBatch(ctx, 100);
    }

    try self.removeSleepingBodies(ctx);
}

fn pushCrateBatch(self: *@This(), ctx: *zigra.Context, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 40,
            (self.rand.random().floatNorm(f32) + 1) * -40,
        };

        try self.active_entities.append(try prototypes.Crate.default(ctx, .{ 0, 0 }, random_vel_chunk));
    }
}

fn pushChunkBatch(self: *@This(), ctx: *zigra.Context, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 40,
            (self.rand.random().floatNorm(f32) + 1) * -40,
        };

        try self.active_entities.append(try prototypes.Chunk.default(ctx, .{ 0, 0 }, random_vel_chunk));
    }
}

fn removeSleepingBodies(self: *@This(), ctx: *zigra.Context) !void {
    const stack_capacity = 128;
    const IndexType = usize;

    var stack_fallback = std.heap.stackFallback(stack_capacity * @sizeOf(IndexType), self.allocator);
    var to_remove = std.ArrayList(IndexType).initCapacity(stack_fallback.get(), stack_capacity) catch unreachable;
    defer to_remove.deinit();

    for (self.active_entities.items, 0..) |id, i| {
        const body = ctx.systems.bodies.bodies.getByEid(id).?;

        switch (body.*) {
            else => @panic("Unimplemented"),
            .point => |p| if (p.sleeping) {
                ctx.systems.entities.destroyEntity(ctx, id);
                try to_remove.append(i);
            } else {
                const transform = ctx.systems.transform.data.getByEid(id).?;
                if (transform.pos[1] > 1000) try to_remove.append(i);
            },
            .rigid => |r| if (r.sleeping) {
                ctx.systems.entities.destroyEntity(ctx, id);
                try to_remove.append(i);
            } else {
                const transform = ctx.systems.transform.data.getByEid(id).?;
                if (transform.pos[1] > 1000) try to_remove.append(i);
            },
        }
    }

    var iterator = std.mem.reverseIterator(to_remove.items);
    while (iterator.next()) |i| _ = self.active_entities.swapRemove(i);
}
