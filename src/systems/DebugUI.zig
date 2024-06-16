const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

const options = @import("options");
const nk = @import("nuklear");

allocator: std.mem.Allocator,

push_arena: std.heap.ArenaAllocator,
view_arena: std.heap.ArenaAllocator,

push_call_profiling_data_nodes: ?*CallProfilingData = null,
view_call_profiling_data: []CallProfilingData = &.{},

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .push_arena = std.heap.ArenaAllocator.init(allocator),
        .view_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.push_arena.deinit();
    self.view_arena.deinit();
    self.* = undefined;
}

pub const CallProfilingData = struct {
    call_name: []const u8,
    start_ns: u64 = 0,
    duration_ns: u64 = 0,
    next: ?*CallProfilingData = null,
};

pub fn pushCallProfilingData(self: *@This(), data: CallProfilingData) !void {
    const old = self.push_call_profiling_data_nodes;

    self.push_call_profiling_data_nodes = try self.push_arena.allocator().create(CallProfilingData);

    self.push_call_profiling_data_nodes.?.* = data;
    self.push_call_profiling_data_nodes.?.next = old;
    self.push_call_profiling_data_nodes.?.call_name =
        try self.push_arena.allocator().dupe(u8, self.push_call_profiling_data_nodes.?.call_name);
}

pub fn processProfilingData(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    if (!options.profiling) return error.Unimplemented;

    if (!self.view_arena.reset(.retain_capacity)) return error.ArenaResetFailed;

    if (self.push_call_profiling_data_nodes) |first_node| {
        var call_nodes_count: usize = 0;
        var node_opt: ?*CallProfilingData = first_node;

        while (node_opt) |node| : (node_opt = node.next) call_nodes_count += 1;

        self.view_call_profiling_data = try self.view_arena.allocator().alloc(CallProfilingData, call_nodes_count);

        var counter: usize = 1;
        node_opt = first_node;

        while (node_opt) |node| : (node_opt = node.next) {
            const cell = &self.view_call_profiling_data[self.view_call_profiling_data.len - counter];
            cell.* = node.*;
            cell.call_name = try self.view_arena.allocator().dupe(u8, cell.call_name);
            counter += 1;
        }
    } else {
        self.view_call_profiling_data = &.{};
    }

    if (!self.push_arena.reset(.retain_capacity)) return error.ArenaResetFailed;

    self.push_call_profiling_data_nodes = null;
}

pub fn processUi(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    switch (ctx.systems.sequencer.state_debug_gui) {
        .Basic => try self.processUi_Basic(ctx),
        .Disabled => {},
    }
}

fn nsToMs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn processUi_Basic(self: *@This(), ctx: *zigra.Context) !void {
    const nk_ctx = &ctx.systems.imgui.nk;

    if (nk.begin(
        nk_ctx,
        "Debug UI",
        .{ .x = 10, .y = 10, .w = 300, .h = 300 },
        &.{ .closeable, .movable, .scalable },
    )) {
        nk.layoutRowDynamic(nk_ctx, 0, 1);
        nk.label(nk_ctx, "General", nk.text_left);

        if (nk.treeBeginHashed(nk_ctx, .node, "Performance", @src(), 0, .maximized)) {
            defer nk.treePop(nk_ctx);

            var buf: [256]u8 = undefined;
            const perf = ctx.systems.time.perf;

            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time ms (last): {d:.1}", .{perf.frame_time_ms_last}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time ms (avg) : {d:.1}", .{perf.frame_time_ms_avg}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time ms (min) : {d:.1}", .{perf.frame_time_ms_min}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "Frame time ms (max) : {d:.1}", .{perf.frame_time_ms_max}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (last): {d:.1}", .{perf.fps_last}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (avg) : {d:.1}", .{perf.fps_avg}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (min) : {d:.1}", .{perf.fps_min}), nk.text_left);
            nk.label(nk_ctx, try std.fmt.bufPrintZ(buf[0..], "FPS (max) : {d:.1}", .{perf.fps_max}), nk.text_left);
        }

        if (nk.treeBeginHashed(nk_ctx, .node, "Loop details", @src(), 0, .maximized)) brk: {
            defer nk.treePop(nk_ctx);

            if (!options.profiling) {
                nk.labelColored(nk_ctx, "Build without profiling support", nk.text_left, .{ .r = 0xff, .b = 0x80, .g = 0x80, .a = 0xff });
                break :brk;
            }

            var buf: [256]u8 = undefined;

            for (self.view_call_profiling_data[0..]) |data| {
                const label = try std.fmt.bufPrintZ(buf[0..], "{s} : {d:.3}", .{ data.call_name, nsToMs(data.duration_ns) });
                nk.label(nk_ctx, label.ptr, nk.text_left);
            }
        }
    } else {
        ctx.systems.sequencer.state_debug_gui = .Disabled;
    }
    nk.end(nk_ctx);
}
