comptime {
    @setFloatMode(.optimized);
}

const std = @import("std");
const builtin = @import("builtin");
const zigra = @import("zigra");
const util = @import("util");

fn create(T: type, allocator: std.mem.Allocator, args: anytype) !*T {
    const o = try allocator.create(T);
    errdefer allocator.destroy(o);
    o.* = try @call(.always_inline, @field(T, "init"), args);
    return o;
}

pub fn main() !void {
    const use_zig_allocator = comptime switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseSmall, .ReleaseFast => false,
    };

    var gpa = if (use_zig_allocator) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer _ = if (use_zig_allocator) gpa.deinit();

    const allocator = if (use_zig_allocator) gpa.allocator() else std.heap.c_allocator;

    const modules = try allocator.create(zigra.Modules);
    defer allocator.destroy(modules);

    var stack_sequencer = util.stack_states.Sequencer(zigra.Modules).init(allocator);
    defer stack_sequencer.deinit();

    const base = try zigra.states.Base.init(.{ .allocator = allocator, .resource_dir = "../res" });
    const playground = try zigra.states.Playground.init(.{ .allocator = allocator });

    try stack_sequencer.setAny(.{ base, playground });
    while (try stack_sequencer.update(modules, 1) != .stable) {}

    while (!modules.window.quit_requested) {
        _ = try stack_sequencer.update(modules, modules.time.ticks_this_checkpoint);
    }

    try stack_sequencer.setAny(.{});
    while (try stack_sequencer.update(modules, 1) != .stable) {}
}
