comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const builtin = @import("builtin");
const zigra = @import("zigra");

pub fn main() !void {
    const use_zig_allocator = comptime switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseSmall, .ReleaseFast => false,
    };

    var gpa = if (use_zig_allocator) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer _ = if (use_zig_allocator) gpa.deinit();

    const allocator = if (use_zig_allocator) gpa.allocator() else std.heap.c_allocator;

    var ctx = try zigra.Context.init(allocator);
    defer ctx.deinit();

    std.log.scoped(.main).info("Context size in bytes: {}", .{@sizeOf(@TypeOf(ctx))});

    try ctx.systems.sequencer.runInit(&ctx.base);
    while (!ctx.systems.window.quit_requested) try ctx.systems.sequencer.runLoop(&ctx.base);
    try ctx.systems.sequencer.runDeinit(&ctx.base);
}
