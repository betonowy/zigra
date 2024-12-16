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
        m.debug_ui.pushSystemProfilingData(m, self.routine_name, self.timer.read()) catch @panic("OOM");
    }
};

fn lastNamePart(comptime name: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[last_dot + 1 ..];
}

pub fn systemTrace(T: type, comptime src: std.builtin.SourceLocation, m: ?*root.Modules) Trace {
    const routine_name = comptime lastNamePart(@typeName(T)) ++ "." ++ src.fn_name;
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
