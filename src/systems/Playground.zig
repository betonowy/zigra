const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

allocator: std.mem.Allocator,
tick: usize = 0,
begin_cam: @Vector(2, i32) = undefined,

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

pub fn tickProcess(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}
