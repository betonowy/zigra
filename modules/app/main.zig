comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const builtin = @import("builtin");
const zigra = @import("zigra");
const util = @import("util");

pub fn main() !void {
    const use_zig_allocator = comptime switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseSmall, .ReleaseFast => false,
    };

    var gpa = if (use_zig_allocator) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer _ = if (use_zig_allocator) gpa.deinit();

    const allocator = if (use_zig_allocator) gpa.allocator() else std.heap.c_allocator;

    const m = try allocator.create(zigra.Modules);
    defer allocator.destroy(m);

    var stack_sequencer = util.stack_states.Sequencer(zigra.Modules).init(allocator);
    defer stack_sequencer.safeDeinit(m);

    const base = try zigra.states.Base.init(.{ .allocator = allocator, .resource_dir = "../res" });
    const playground = try zigra.states.Playground.init(.{ .allocator = allocator });

    try stack_sequencer.setAny(.{ base, playground });
    while (try stack_sequencer.update(m, 1) != .stable) {}

    while (!m.window.quit_requested) {
        _ = try stack_sequencer.update(m, m.time.ticks_this_checkpoint);
    }

    try stack_sequencer.setAny(.{});
    while (try stack_sequencer.update(m, 1) != .stable) {}
}
