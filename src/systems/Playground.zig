const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

id_first_crate: u32 = undefined,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .allocator = allocator };
}

pub fn systemInit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try ctx.systems.world.sand_sim.loadFromPngFile(.{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } }, "land/TEST_LEVEL_WATERFALL_BIGGAP.png");
}

pub fn systemDeinit(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn tickProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    switch (ctx.systems.time.tick_current) {
        200 => self.id_first_crate = try prototypes.Chunk.default(ctx, .{ 0, 0 }, .{ 0, 0 }),
        500 => ctx.systems.entities.destroyEntity(ctx, self.id_first_crate),
        else => {},
    }
}
