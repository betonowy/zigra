const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const root = @import("../root.zig");

const options = @import("options");
const nk = @import("nuklear");
const common = @import("common.zig");

allocator: std.mem.Allocator,
view_arena: std.heap.ArenaAllocator,
mtx: std.Thread.Mutex = .{},

view_system_call_profiling_data: []SysCtxHashMap.Entry = &.{},
profiling_system_ctx_map: SysCtxHashMap,

state: WindowState = .enabled,
w_general: bool = false,
w_entities: bool = false,
w_atlas: bool = false,
w_profiling: bool = false,
w_preferences: bool = false,

pref_chart_height: i32 = 50,
pref_chart_type: ChartType = .Scanning,

text_field: std.BoundedArray(u8, 64) = .{},

const chart_base_color = nk.Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff };
const chart_active_color = nk.Color{ .r = 0xa0, .g = 0x40, .b = 0x40, .a = 0xff };

const ChartType = enum {
    Running,
    Scanning,
};

const SysCtxHashMap = std.StringHashMap(CallProfilingCtx);

pub const WindowState = enum { disabled, enabled };

const CallProfilingCtx = struct {
    times_ms: [256]f32 = std.mem.zeroes([256]f32),
    index_current: usize = 0,
    index_extent: usize = 0,
    time_updated: u64 = 0,
    all_time_max: f32 = 0,

    pub fn push(self: *@This(), ns: u64, timestamp: u64) void {
        const value = nsToMs(ns);
        self.times_ms[self.index_current] = value;
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

    pub fn stats(self: *@This()) Stats {
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

        self.all_time_max = @max(self.all_time_max, max);

        const target_a = (max - avg) * 2 + avg;
        const target_b = avg * 1.5;

        self.all_time_max = std.math.lerp(self.all_time_max, @max(target_a, target_b), 0.01);

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
    var arr = std.BoundedArray(u8, 64){};
    try arr.appendSlice("items: []const T");

    return .{
        .allocator = allocator,
        .view_arena = std.heap.ArenaAllocator.init(allocator),
        .profiling_system_ctx_map = SysCtxHashMap.init(allocator),
        .text_field = arr,
    };
}

pub fn deinit(self: *@This()) void {
    self.profiling_system_ctx_map.deinit();
    self.view_arena.deinit();
    self.* = undefined;
}

fn nsToMs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
}

pub fn pushOtherProfilingData(self: *@This(), data: CallProfilingData) !void {
    self.mtx.lock();
    defer self.mtx.unlock();

    const entry = try self.profiling_ctx_map.getOrPutAdapted(data.call_name, self.profiling_ctx_map.ctx);

    if (entry.found_existing) {
        entry.value_ptr.push(data.duration_ns, data.timestamp);
    } else {
        entry.key_ptr.* = try self.allocator.dupe(u8, data.call_name);
        entry.value_ptr.* = .{};
    }
}

pub fn pushSystemProfilingData(self: *@This(), m: *root.Modules, routine_name: []const u8, ns: u64) !void {
    self.mtx.lock();
    defer self.mtx.unlock();

    const result = try self.profiling_system_ctx_map.getOrPut(routine_name);
    if (!result.found_existing) result.value_ptr.* = .{};
    result.value_ptr.push(ns, m.time.timer_main.read());
}

pub fn processData(self: *@This(), _: *root.Modules) anyerror!void {
    if (!options.profiling) return error.Unimplemented;

    self.mtx.lock();
    defer self.mtx.unlock();

    if (!self.view_arena.reset(.retain_capacity)) return error.ArenaResetFailed;

    self.view_system_call_profiling_data = try self.view_arena.allocator().alloc(SysCtxHashMap.Entry, self.profiling_system_ctx_map.count());
    {
        var counter: usize = 0;
        var map = self.profiling_system_ctx_map.iterator();
        while (map.next()) |entry| : (counter += 1) self.view_system_call_profiling_data[counter] = entry;
    }

    const sort = struct {
        pub fn ltSysCtxHashMap(_: void, lhs: SysCtxHashMap.Entry, rhs: SysCtxHashMap.Entry) bool {
            return lhs.value_ptr.time_updated < rhs.value_ptr.time_updated;
        }
    };

    std.sort.pdq(SysCtxHashMap.Entry, self.view_system_call_profiling_data, {}, sort.ltSysCtxHashMap);
}

pub fn doUi(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    self.mtx.lock();
    defer self.mtx.unlock();

    if (self.state == .disabled) return;

    const nk_ctx = &m.nuklear.nk_ctx;

    const button_count = 4 + if (options.profiling) 1 else 0;
    const window_width = 112;
    const window_height = 32 + button_count * 24;

    if (nk.begin(
        nk_ctx,
        "Debug UI",
        .{ .x = 8, .y = 8, .w = window_width, .h = window_height },
        &.{ .closeable, .movable, .no_scrollbar, .border },
    )) {
        nk.layoutRowStatic(nk_ctx, 20, 100, 1);
        if (self.processUi_tabButton(nk_ctx, "General", self.w_general)) self.w_general = !self.w_general;
        if (self.processUi_tabButton(nk_ctx, "Entities", self.w_entities)) self.w_entities = !self.w_entities;
        if (self.processUi_tabButton(nk_ctx, "Atlas", self.w_atlas)) self.w_atlas = !self.w_atlas;
        if (options.profiling and self.processUi_tabButton(nk_ctx, "Profiling", self.w_profiling)) self.w_profiling = !self.w_profiling;
        if (self.processUi_tabButton(nk_ctx, "Preferences", self.w_preferences)) self.w_preferences = !self.w_preferences;
    } else {
        self.state = .disabled;
    }
    nk.end(nk_ctx);

    if (self.w_general) try self.processUi_General(m);
    if (self.w_entities) try self.processUi_Entities(m);
    if (self.w_atlas) try self.processUi_Atlas(m);
    if (self.w_profiling) try self.processUi_Profiling(m);
    if (self.w_preferences) try self.processUi_Preferences(m);
}

fn processUi_tabButton(_: *@This(), nk_ctx: *nk.Context, title: [*:0]const u8, selected: bool) bool {
    const normal = nk.Color{ .r = 0x20, .g = 0x60, .b = 0x10, .a = 0xff };
    const hover = nk.Color{ .r = 0x20, .g = 0x40, .b = 0x10, .a = 0xff };
    const active = nk.Color{ .r = 0x20, .g = 0x20, .b = 0x10, .a = 0xff };

    return switch (selected) {
        true => nk.buttonLabelColored(nk_ctx, title, normal, hover, active),
        false => nk.buttonLabel(nk_ctx, title),
    };
}

fn processUi_General(self: *@This(), m: *root.Modules) !void {
    const nk_ctx = &m.nuklear.nk_ctx;

    if (nk.begin(nk_ctx, "General", .{ .x = 128, .y = 8, .w = 200, .h = 230 }, &.{ .movable, .closeable, .border })) {
        if (nk.treeBeginHashed(nk_ctx, .node, "Performance", @src(), 0, .maximized)) {
            defer nk.treePop(nk_ctx);

            var buf: [64]u8 = undefined;
            const perf = m.time.perf;

            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (avg): {d:.1} ms", .{perf.frame_time_ms_avg}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (min): {d:.1} ms", .{perf.frame_time_ms_min}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (max): {d:.1} ms", .{perf.frame_time_ms_max}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time (now): {d:.1} ms", .{perf.frame_time_ms_now}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (avg): {d:.1}", .{perf.fps_avg}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (min): {d:.1}", .{perf.fps_min}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (max): {d:.1}", .{perf.fps_max}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (now): {d:.1}", .{perf.fps_now}), nk.text_left);
        }
    } else {
        self.w_general = false;
    }
    nk.end(nk_ctx);
}

fn processUi_Entities(self: *@This(), m: *root.Modules) !void {
    const nk_ctx = &m.nuklear.nk_ctx;

    if (nk.begin(nk_ctx, "Entities", .{ .x = 128, .y = 8, .w = 350, .h = 400 }, &.{ .movable, .closeable, .scalable, .border })) {
        nk.layoutRowDynamic(nk_ctx, 10, 1);
        nk.label(nk_ctx, "  arrayId:pc:generation:name", nk.text_left);
        nk.layoutRowDynamic(nk_ctx, 1, 1);
        nk.rule(nk_ctx, nk_ctx.style.text.color);

        var buf: [1024]u8 = undefined;

        for (0..m.entities.store.arr.capacity, m.entities.store.arr.data[0..]) |i, k| {
            if (m.entities.store.arr.tryAt(@intCast(i)) != null) {
                if (nk.treeBeginHashed(nk_ctx, .tab, try std.fmt.bufPrintZ(
                    buf[0..],
                    "{:07}:{:02}:{x:010}:{s}",
                    .{ i, k.descriptor.player, k.descriptor.gen, k.data.vt.name },
                ), @src(), @intCast(k.descriptor.gen), .minimized)) {
                    defer nk.treePop(nk_ctx);

                    nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "deinit:0x{x}", .{@intFromPtr(k.data.vt.deinit_fn)}), nk.text_left);

                    const normal = nk.Color{ .r = 0x60, .g = 0x20, .b = 0x10, .a = 0xff };
                    const hover = nk.Color{ .r = 0x40, .g = 0x20, .b = 0x10, .a = 0xff };
                    const active = nk.Color{ .r = 0x20, .g = 0x20, .b = 0x10, .a = 0xff };

                    if (nk.buttonLabelColored(nk_ctx, "Destroy", normal, hover, active)) {
                        try m.entities.deferDestroyEntity(.{ .index = @intCast(i), .gen = k.descriptor.gen, .player = k.descriptor.player });
                    }
                }
            } else {}
        }
    } else {
        self.w_entities = false;
    }
    nk.end(nk_ctx);
}

fn processUi_Atlas(self: *@This(), m: *root.Modules) !void {
    _ = m; // autofix
    _ = self; // autofix
    // const nk_ctx = &m.nuklear.nk_ctx;
    // var buf: [1024]u8 = undefined;

    // const extent = m.vulkan.impl.atlas.image.extent;

    // if (nk.begin(nk_ctx, "Atlas", .{ .x = 128, .y = 8, .w = 200, .h = 200 }, &.{ .movable, .closeable, .scalable, .border })) {
    //     nk.layoutRowDynamic(nk_ctx, 10, 1);
    //     nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Atlas size: {}x{}", .{ extent.width, extent.height }), nk.text_left);

    //     nk.layoutRowDynamic(nk_ctx, 1, 1);
    //     nk.rule(nk_ctx, nk_ctx.style.text.color);

    //     nk.layoutRowStatic(nk_ctx, @floatFromInt(extent.height), @intCast(extent.width), 1);
    //     nk.image(nk_ctx, .{
    //         .handle = 0,
    //         .size = .{ @intCast(extent.width), @intCast(extent.height) },
    //     });
    // } else {
    //     self.w_atlas = false;
    // }
    // nk.end(nk_ctx);
}

fn processUi_Profiling(self: *@This(), m: *root.Modules) !void {
    const nk_ctx = &m.nuklear.nk_ctx;

    var all_average_time: f32 = 0;
    for (self.view_system_call_profiling_data[0..]) |data| all_average_time += data.value_ptr.stats().avg;
    all_average_time /= @floatFromInt(self.view_system_call_profiling_data.len);

    if (nk.begin(nk_ctx, "Profiling", .{ .x = 128, .y = 8, .w = 380, .h = 390 }, &.{ .movable, .closeable, .scalable, .border })) {
        for (self.view_system_call_profiling_data[0..], 0..) |data, i| {
            // TODO add filter and colors for quality of life
            try self.processUi_statsEntry(nk_ctx, data.key_ptr.*, data.value_ptr, i, all_average_time, @src());
        }
    } else {
        self.w_profiling = false;
    }
    nk.end(nk_ctx);
}

fn processUi_Preferences(self: *@This(), m: *root.Modules) !void {
    const nk_ctx = &m.nuklear.nk_ctx;

    if (nk.begin(nk_ctx, "Preferences", .{ .x = 128, .y = 8, .w = 200, .h = 200 }, &.{ .movable, .closeable, .scalable, .border })) {
        nk.layoutRowDynamic(nk_ctx, 0, 1);
        nk.label(nk_ctx, "Chart height", nk.text_center);
        _ = nk.sliderI32(nk_ctx, 20, &self.pref_chart_height, 200, 1);

        nk.layoutRowDynamic(nk_ctx, @floatFromInt(self.pref_chart_height), 1);
        if (nk.chartBeginColored(nk_ctx, .lines, chart_base_color, chart_active_color, 10, -1, 1)) {
            const mod = @as(f32, @floatFromInt(m.time.time_ns)) / std.time.ns_per_s;
            for (0..10) |i| nk.chartPush(nk_ctx, @sin(@as(f32, @floatFromInt(i)) + mod));
            nk.chartEnd(nk_ctx);
        }

        nk.layoutRowDynamic(nk_ctx, 1, 1);
        nk.rule(nk_ctx, nk_ctx.style.text.color);
        nk.layoutRowDynamic(nk_ctx, 10, 1);
        nk.label(nk_ctx, "Chart update method", nk.text_center);
        nk.layoutRowDynamic(nk_ctx, 10, 2);
        {
            var active = self.pref_chart_type == .Running;
            nk.radioLabel(nk_ctx, "Running", &active);
            if (active) self.pref_chart_type = .Running;
        }
        {
            var active = self.pref_chart_type == .Scanning;
            nk.radioLabel(nk_ctx, "Scanning", &active);
            if (active) self.pref_chart_type = .Scanning;
        }
    } else {
        self.w_preferences = false;
    }
    nk.end(nk_ctx);
}

fn processUi_statsEntry(
    self: *@This(),
    nk_ctx: *nk.Context,
    name: []const u8,
    profiling_ctx: *CallProfilingCtx,
    index: usize,
    all_average_time: f32,
    comptime src: std.builtin.SourceLocation,
) !void {
    var buf: [256]u8 = undefined;

    const stats = profiling_ctx.stats();

    const base_color_value = std.math.clamp(@sqrt(stats.avg / all_average_time), 0, 5.0);
    const other_color_value = 1 - std.math.clamp(@sqrt(stats.avg / all_average_time), 0, 1.0) * 0.2;

    const color = nk_ctx.style.tab.background.data.color;

    if (nk.treeBeginHashedColor(nk_ctx, .tab, try std.fmt.bufPrintZ(
        buf[0..],
        "{d:.3} ms (avg) | {s}",
        .{ stats.avg, name },
    ), src, @intCast(index), .minimized, .{
        .a = color.a,
        .r = @intFromFloat(std.math.clamp(base_color_value * @as(f32, @floatFromInt(color.r)), 0, 255)),
        .g = @intFromFloat(std.math.clamp(other_color_value * @as(f32, @floatFromInt(color.g)), 0, 255)),
        .b = @intFromFloat(std.math.clamp(other_color_value * @as(f32, @floatFromInt(color.b)), 0, 255)),
    })) {
        defer nk.treePop(nk_ctx);

        nk.label(nk_ctx, try std.fmt.bufPrintZ(
            buf[0..],
            "{d:.3} ms (min), {d:.3} ms (max), {d:.3} ms (now)",
            .{ stats.min, stats.max, stats.now },
        ), nk.text_left);

        self.processUi_plot(nk_ctx, profiling_ctx);
    }
}

fn processUi_plot(self: *@This(), nk_ctx: *nk.Context, profiling_ctx: *CallProfilingCtx) void {
    nk.layoutRowDynamic(nk_ctx, @floatFromInt(self.pref_chart_height), 1);
    if (nk.chartBeginColored(nk_ctx, .lines, chart_base_color, chart_active_color, @intCast(profiling_ctx.index_extent), 0, profiling_ctx.all_time_max)) {
        switch (self.pref_chart_type) {
            .Scanning => for (profiling_ctx.times_ms[0..]) |v| nk.chartPush(nk_ctx, v),
            .Running => {
                for (profiling_ctx.times_ms[profiling_ctx.index_current + 1 ..]) |v| nk.chartPush(nk_ctx, v);
                for (profiling_ctx.times_ms[0..profiling_ctx.index_current]) |v| nk.chartPush(nk_ctx, v);
            },
        }
        nk.chartEnd(nk_ctx);
    }
}
