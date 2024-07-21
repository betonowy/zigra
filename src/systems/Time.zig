const std = @import("std");
const lifetime = @import("../lifetime.zig");

const cfg_ns_per_tick = 20 * std.time.ns_per_ms;
const cfg_tick_per_checkpoint_max = 10;

allocator: std.mem.Allocator,
timer_main: std.time.Timer,

/// time since system init
time_ns: u64 = 0,
/// essentially frame time
time_checkpoint_delay_ns: u64 = 0,

/// target tick number for checkpoint
tick_final: u64 = 0,
/// current tick number
tick_current: u64 = 0,
/// drift of the last tick
tick_drift_ns: i64 = 0,
/// ticks that need be performed this checkpoint
ticks_this_checkpoint: u64 = 0,

perf: struct {
    fps_now: f32,
    fps_avg: f32,
    fps_min: f32,
    fps_max: f32,

    frame_time_ms_now: f32,
    frame_time_ms_avg: f32,
    frame_time_ms_min: f32,
    frame_time_ms_max: f32,
} = undefined,

perf_internal: struct {
    frame_times: [256]f32 = undefined,
    index_current: usize = 0,
    index_extent: usize = 0,
} = .{},

cfg_minimum_checkpoint_delay_ns: u64 = 10 * std.time.ns_per_ms,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .timer_main = try std.time.Timer.start(),
    };
}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn checkpoint(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    const last_ns = self.time_ns;
    self.time_ns = self.timer_main.read();
    self.time_checkpoint_delay_ns = self.time_ns - last_ns;

    const target_tick = (self.time_ns + cfg_ns_per_tick / 2) / cfg_ns_per_tick;
    self.ticks_this_checkpoint = target_tick - self.tick_final;
    self.tick_drift_ns = @as(i64, @intCast(target_tick * cfg_ns_per_tick)) - @as(i64, @intCast(self.time_ns));

    self.ticks_this_checkpoint = @min(self.ticks_this_checkpoint, cfg_tick_per_checkpoint_max);
    self.tick_final = target_tick;

    self.calculatePerfCounters();
}

pub fn ensureMinimumCheckpointTime(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    const now_ns = self.timer_main.read();

    const wait_for_ns =
        @as(i64, @intCast(self.cfg_minimum_checkpoint_delay_ns)) -
        @as(i64, @intCast(now_ns - self.time_ns));

    if (wait_for_ns <= 0) return;

    std.time.sleep(@intCast(wait_for_ns));
}

pub fn finishTick(self: *@This(), _: *lifetime.ContextBase) !void {
    self.tick_current += 1;
}

pub fn tickDrift(self: *const @This()) f32 {
    return @as(f32, @floatFromInt(self.tick_drift_ns)) * (1.0 / @as(comptime_float, std.time.ns_per_s));
}

pub fn tickDelay(_: *const @This()) f32 {
    return cfg_ns_per_tick * (1.0 / @as(comptime_float, std.time.ns_per_s));
}

pub fn checkpointDelay(self: *const @This()) f32 {
    return self.time_checkpoint_delay_ns * (1.0 / std.time.ns_per_s);
}

fn calculatePerfCounters(self: *@This()) void {
    self.perf_internal.frame_times[self.perf_internal.index_current] = @floatFromInt(self.time_checkpoint_delay_ns);
    self.perf_internal.index_extent = @max(self.perf_internal.index_current + 1, self.perf_internal.index_extent);

    self.perf.frame_time_ms_now = self.perf_internal.frame_times[self.perf_internal.index_current];
    self.perf.frame_time_ms_max = self.perf.frame_time_ms_now;
    self.perf.frame_time_ms_min = self.perf.frame_time_ms_now;
    self.perf.frame_time_ms_avg = 0;

    for (self.perf_internal.frame_times[0..self.perf_internal.index_extent]) |n| {
        self.perf.frame_time_ms_max = @max(self.perf.frame_time_ms_max, n);
        self.perf.frame_time_ms_min = @min(self.perf.frame_time_ms_min, n);
        self.perf.frame_time_ms_avg += n;
    }

    self.perf.frame_time_ms_avg /= @floatFromInt(self.perf_internal.index_extent);
    self.perf_internal.index_current = (self.perf_internal.index_current + 1) % self.perf_internal.frame_times.len;

    self.perf.fps_now = @as(f32, std.time.ns_per_s) / self.perf.frame_time_ms_now;
    self.perf.fps_max = @as(f32, std.time.ns_per_s) / self.perf.frame_time_ms_min;
    self.perf.fps_min = @as(f32, std.time.ns_per_s) / self.perf.frame_time_ms_max;
    self.perf.fps_avg = @as(f32, std.time.ns_per_s) / self.perf.frame_time_ms_avg;

    self.perf.frame_time_ms_now *= (1.0 / @as(f32, std.time.ns_per_ms));
    self.perf.frame_time_ms_max *= (1.0 / @as(f32, std.time.ns_per_ms));
    self.perf.frame_time_ms_min *= (1.0 / @as(f32, std.time.ns_per_ms));
    self.perf.frame_time_ms_avg *= (1.0 / @as(f32, std.time.ns_per_ms));
}
