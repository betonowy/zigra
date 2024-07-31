const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

id_chunk: u32 = undefined,
id_crate: u32 = undefined,
rand: std.Random.DefaultPrng,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .rand = std.Random.DefaultPrng.init(395828523321213),
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

    const random_vel_chunk: @Vector(2, f32) = .{
        self.rand.random().floatNorm(f32) * 40,
        (self.rand.random().floatNorm(f32) + 1) * -40,
    };

    const random_vel_crate: @Vector(2, f32) = .{
        self.rand.random().floatNorm(f32) * 40,
        (self.rand.random().floatNorm(f32) + 1) * -40,
    };

    // const random_vel_crate: @Vector(2, f32) = .{ 1.30867904e+02, 9.06891822e-01 };

    switch (ctx.systems.time.tick_current % 410) {
        0 => {
            self.id_chunk = try prototypes.Chunk.default(ctx, .{ 0.1, -50 }, random_vel_chunk);
            self.id_crate = try prototypes.Crate.default(ctx, .{ 10, -50 }, random_vel_crate);
            std.log.info("Crate spawn vel: {}", .{random_vel_crate});
        },
        400 => {
            ctx.systems.entities.destroyEntity(ctx, self.id_chunk);
            ctx.systems.entities.destroyEntity(ctx, self.id_crate);
        },
        else => {},
    }
}
