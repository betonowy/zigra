const std = @import("std");
const common = @import("common.zig");

allocator: std.mem.Allocator,
impl: *std.Thread.Pool,

pub fn init(allocator: std.mem.Allocator) !@This() {
    const optimal_thread_count = @max(try std.Thread.getCpuCount() - 1, 1);

    var tp = try allocator.create(std.Thread.Pool);
    errdefer allocator.destroy(tp);

    try tp.init(.{ .allocator = allocator, .n_jobs = optimal_thread_count });
    errdefer tp.deinit();

    var scratch_buf: [64]u8 = undefined;
    for (tp.threads, 0..) |thread, i| try thread.setName(
        try std.fmt.bufPrint(&scratch_buf, "pool[{:03}]", .{i}),
    );

    return .{ .allocator = allocator, .impl = tp };
}

pub fn deinit(self: *@This()) void {
    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    self.impl.deinit();
    self.allocator.destroy(self.impl);
}

pub fn spawn(self: @This(), comptime func: anytype, args: anytype) void {
    self.impl.spawn(func, args) catch @call(.auto, func, args);
}

pub fn spawnWg(self: @This(), wait_group: *std.Thread.WaitGroup, comptime func: anytype, args: anytype) void {
    self.impl.spawnWg(wait_group, func, args);
}

pub fn spawnWgId(self: @This(), wait_group: *std.Thread.WaitGroup, comptime func: anytype, args: anytype) void {
    self.impl.spawnWgId(wait_group, func, args);
}
