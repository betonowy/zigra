const std = @import("std");
const tracy = @import("tracy");
const root = @import("../root.zig");
const options = @import("options");

const internal_profiling = options.debug_ui and options.profiling;

const Trace = struct {
    tracy: tracy.Ctx,
    timer: std.time.Timer,
    routine_name: []const u8,
    m: ?*root.Modules,

    pub fn end(self: *@This()) void {
        self.tracy.end();
        if (!internal_profiling) return;
        const m = self.m orelse return;

        const ns = self.timer.read();
        const result = m.debug_ui.profiling_system_ctx_map.getOrPut(self.routine_name) catch @panic("OOM");
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.push(ns, m.time.timer_main.read());
    }
};

pub fn systemTrace(T: type, comptime src: std.builtin.SourceLocation, m: ?*root.Modules) Trace {
    const routine_name = @typeName(T) ++ "." ++ src.fn_name;
    return .{
        .tracy = tracy.traceNamed(src, routine_name),
        .timer = if (m != null and internal_profiling) std.time.Timer.start() catch unreachable else undefined,
        .routine_name = routine_name,
        .m = m,
    };
}

pub fn systemMessage(T: type, comptime src: std.builtin.SourceLocation) void {
    tracy.message(@typeName(T) ++ "." ++ src.fn_name);
}
