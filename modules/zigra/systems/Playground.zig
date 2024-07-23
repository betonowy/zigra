const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

id_first_crate: u32 = undefined,
rand: std.Random.Sfc64,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .rand = std.Random.Sfc64.init(1),
    };
}

pub fn systemInit(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try ctx.systems.world.sand_sim.loadFromPngFile(.{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } }, "land/TEST_LEVEL_WATERFALL_BIGGAP.png");

    for (0..3) |_| {
        _ = self.rand.random().floatNorm(f32);
        _ = self.rand.random().floatNorm(f32);
    }
}

pub fn systemDeinit(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn tickProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    const random_vel: @Vector(2, f32) = .{
        self.rand.random().floatNorm(f32) * 15,
        (self.rand.random().floatNorm(f32) + 1) * 15,
    };

    switch (ctx.systems.time.tick_current % 400) {
        0 => self.id_first_crate = try prototypes.Chunk.default(ctx, .{ 0.1, 10 }, random_vel),
        390 => ctx.systems.entities.destroyEntity(ctx, self.id_first_crate),
        else => {},
    }
}
