comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const zigra = @import("zigra");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ctx = try zigra.Context.init(gpa.allocator());
    defer ctx.deinit();

    std.log.scoped(.main).info("Context size in bytes: {}", .{@sizeOf(@TypeOf(ctx))});

    try ctx.systems.sequencer.runInit(&ctx.base);
    while (!ctx.systems.window.quit_requested) try ctx.systems.sequencer.runLoop(&ctx.base);
    // try ctx.systems.sequencer.runLoop(&ctx.base);
    try ctx.systems.sequencer.runDeinit(&ctx.base);
}
