const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

const options = @import("options");
const nk = @import("nuklear");

allocator: std.mem.Allocator,
view_arena: std.heap.ArenaAllocator,
view_call_profiling_data: []CtxHashMap.Entry = &.{},
view_system_call_profiling_data: []SysCtxHashMap.Entry = &.{},

profiling_ctx_map: CtxHashMap,
profiling_system_ctx_map: SysCtxHashMap,

state: WindowState = .General,

const CtxHashMap = std.StringHashMap(CallProfilingCtx);
const SysCtxHashMap = std.StringHashMap(CallProfilingCtx);

pub const WindowState = enum {
    Disabled,
    General,
    Systems,
};

const CallProfilingCtx = struct {
    times_ms: [256]f32 = undefined,
    index_current: usize = 0,
    index_extent: usize = 0,
    time_updated: u64 = 0,

    pub fn push(self: *@This(), ns: u64, timestamp: u64) void {
        self.times_ms[self.index_current] = nsToMs(ns);
        self.index_extent = @max(self.index_current + 1, self.index_extent);
        self.index_current = (self.index_current + 1) % self.times_ms.len;

        if (self.time_updated == 0) self.time_updated = timestamp;
    }

    pub const NamedStats = struct {
        name: []const u8,
        stats: Stats,
    };

    pub const Stats = struct {
        now: f32,
        avg: f32,
        min: f32,
        max: f32,
    };

    pub fn stats(self: *const @This()) Stats {
        const now = self.times_ms[self.index_current];
        var min = now;
        var max = now;
        var avg: f32 = 0;

        for (self.times_ms[0..self.index_extent]) |v| {
            max = @max(max, v);
            min = @min(min, v);
            avg += v;
        }

        avg *= (1.0 / @as(f32, @floatFromInt(self.index_extent)));

        return .{ .now = now, .avg = avg, .min = min, .max = max };
    }
};

pub const CallProfilingData = struct {
    call_name: []const u8,
    timestamp: u64 = 0,
    duration_ns: u64 = 0,
    next: ?*CallProfilingData = null,
};

pub const ProfilingType = enum {
    PreTick,
    Tick,
    PostTick,
    Other,
};

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .view_arena = std.heap.ArenaAllocator.init(allocator),
        .profiling_ctx_map = CtxHashMap.init(allocator),
        .profiling_system_ctx_map = SysCtxHashMap.init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    {
        var map = self.profiling_ctx_map.keyIterator();
        while (map.next()) |entry| self.allocator.free(entry.*);
    }
    {
        // var map = self.profiling_system_ctx_map.keyIterator();
        // while (map.next()) |entry| self.allocator.free(entry.*);
    }
    self.profiling_ctx_map.deinit();
    self.profiling_system_ctx_map.deinit();
    self.view_arena.deinit();
    self.* = undefined;
}

fn nsToMs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
}

pub fn pushOtherProfilingData(self: *@This(), data: CallProfilingData) !void {
    const entry = try self.profiling_ctx_map.getOrPutAdapted(data.call_name, self.profiling_ctx_map.ctx);

    if (entry.found_existing) {
        entry.value_ptr.push(data.duration_ns, data.timestamp);
    } else {
        entry.key_ptr.* = try self.allocator.dupe(u8, data.call_name);
        entry.value_ptr.* = .{};
    }
}

pub fn processProfilingData(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    if (!options.profiling) return error.Unimplemented;

    if (!self.view_arena.reset(.retain_capacity)) return error.ArenaResetFailed;

    self.view_call_profiling_data = try self.view_arena.allocator().alloc(CtxHashMap.Entry, self.profiling_ctx_map.count());
    {
        var counter: usize = 0;
        var map = self.profiling_ctx_map.iterator();
        while (map.next()) |entry| : (counter += 1) self.view_call_profiling_data[counter] = entry;
    }

    self.view_system_call_profiling_data = try self.view_arena.allocator().alloc(SysCtxHashMap.Entry, self.profiling_system_ctx_map.count());
    {
        var counter: usize = 0;
        var map = self.profiling_system_ctx_map.iterator();
        while (map.next()) |entry| : (counter += 1) self.view_system_call_profiling_data[counter] = entry;
    }

    const sort = struct {
        pub fn ltCtxHashMap(_: void, lhs: CtxHashMap.Entry, rhs: CtxHashMap.Entry) bool {
            return lhs.value_ptr.time_updated < rhs.value_ptr.time_updated;
        }

        pub fn ltSysCtxHashMap(_: void, lhs: SysCtxHashMap.Entry, rhs: SysCtxHashMap.Entry) bool {
            return lhs.value_ptr.time_updated < rhs.value_ptr.time_updated;
        }
    };

    std.sort.pdq(CtxHashMap.Entry, self.view_call_profiling_data, {}, sort.ltCtxHashMap);
    std.sort.pdq(CtxHashMap.Entry, self.view_system_call_profiling_data, {}, sort.ltSysCtxHashMap);
}

pub fn processUi(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    if (self.state == .Disabled) return;

    const ctx = ctx_base.parent(zigra.Context);
    const nk_ctx = &ctx.systems.imgui.nk;

    if (nk.begin(
        nk_ctx,
        "Debug UI",
        .{ .x = 10, .y = 10, .w = 300, .h = 400 },
        &.{ .closeable, .movable, .scalable },
    )) {
        nk.layoutRowStatic(nk_ctx, 20, 80, 2);
        if (processUi_tabButton(nk_ctx, "General", self.state == .General)) self.state = .General;
        if (processUi_tabButton(nk_ctx, "Systems", self.state == .Systems)) self.state = .Systems;

        nk.layoutRowDynamic(nk_ctx, 1, 1);
        nk.rule(nk_ctx, nk_ctx.style.text.color);

        switch (self.state) {
            .General => try self.processUi_General(ctx),
            .Systems => try self.processUi_Systems(ctx),
            .Disabled => {},
        }
    } else {
        self.state = .Disabled;
    }
    nk.end(nk_ctx);
}

fn processUi_tabButton(nk_ctx: *nk.Context, title: [*:0]const u8, selected: bool) bool {
    const normal = nk.Color{ .r = 0x20, .g = 0x60, .b = 0x10, .a = 0xff };
    const hover = nk.Color{ .r = 0x20, .g = 0x40, .b = 0x10, .a = 0xff };
    const active = nk.Color{ .r = 0x20, .g = 0x20, .b = 0x10, .a = 0xff };

    return switch (selected) {
        true => nk.buttonLabelColored(nk_ctx, title, normal, hover, active),
        false => nk.buttonLabel(nk_ctx, title),
    };
}

fn processUi_General(self: *@This(), ctx: *zigra.Context) !void {
    const nk_ctx = &ctx.systems.imgui.nk;

    if (nk.treeBeginHashed(nk_ctx, .node, "Performance", @src(), 0, .maximized)) {
        defer nk.treePop(nk_ctx);

        var buf: [256]u8 = undefined;
        const perf = ctx.systems.time.perf;

        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (avg): {d:.1} ms", .{perf.frame_time_ms_avg}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (min): {d:.1} ms", .{perf.frame_time_ms_min}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (max): {d:.1} ms", .{perf.frame_time_ms_max}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (now): {d:.1} ms", .{perf.frame_time_ms_now}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (avg): {d:.1}", .{perf.fps_avg}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (min): {d:.1}", .{perf.fps_min}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (max): {d:.1}", .{perf.fps_max}), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (now): {d:.1}", .{perf.fps_now}), nk.text_left);
    }

    if (nk.treeBeginHashed(nk_ctx, .node, "Loop details", @src(), 0, .maximized)) brk: {
        defer nk.treePop(nk_ctx);

        if (!options.profiling) {
            nk.labelColored(nk_ctx, "Build without profiling support", nk.text_left, .{ .r = 0xff, .b = 0x80, .g = 0x80, .a = 0xff });
            break :brk;
        }

        for (self.view_call_profiling_data[0..], 0..) |data, i| {
            try processUi_statsEntry(nk_ctx, data.key_ptr.*, data.value_ptr.stats(), i);
        }
    }
}

fn processUi_Systems(self: *@This(), ctx: *zigra.Context) !void {
    const nk_ctx = &ctx.systems.imgui.nk;

    for (self.view_system_call_profiling_data[0..], 0..) |data, i| {
        try processUi_statsEntry(nk_ctx, data.key_ptr.*, data.value_ptr.stats(), i);
    }
}

fn processUi_statsEntry(nk_ctx: *nk.Context, name: []const u8, stats: CallProfilingCtx.Stats, index: usize) !void {
    var buf: [256]u8 = undefined;

    if (nk.treeBeginHashed(nk_ctx, .tab, try std.fmt.bufPrintZ(
        buf[0..],
        "{s} (avg): {d:.3} ms",
        .{ name, stats.avg },
    ), @src(), @intCast(index), .minimized)) {
        defer nk.treePop(nk_ctx);

        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "{s} (min): {d:.3} ms", .{ name, stats.min }), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "{s} (max): {d:.3} ms", .{ name, stats.max }), nk.text_left);
        nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "{s} (now): {d:.3} ms", .{ name, stats.now }), nk.text_left);
    }
}
