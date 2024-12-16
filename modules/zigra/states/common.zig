const std = @import("std");
const tracy = @import("tracy");
const options = @import("options");
const root = @import("../root.zig");

pub fn run(m: *root.Modules, comptime system_tag: anytype, comptime function_tag: anytype) !void {
    return runEx(m, system_tag, function_tag, .profiling);
}

pub fn runLean(m: *root.Modules, comptime system_tag: anytype, comptime function_tag: anytype) !void {
    return runEx(m, system_tag, function_tag, .lean);
}

fn runEx(
    m: *root.Modules,
    comptime system_tag: anytype,
    comptime function_tag: anytype,
    args: anytype,
    comptime flavor: enum { lean, profiling },
) !void {
    const system_ptr = &@field(m, @tagName(system_tag));
    const routine_name = @tagName(system_tag) ++ "." ++ @tagName(function_tag);

    const T: type = @TypeOf(system_ptr.*);
    const callable = @field(T, @tagName(function_tag));
    const fn_type = @typeInfo(@TypeOf(callable(system_ptr, &m.base))).@"fn";

    if (options.profiling and options.debug_ui and flavor == .profiling) {
        var timer = try std.time.Timer.start();
        {
            const t = tracy.traceNamed(@src(), routine_name);
            defer t.end();

            switch (@typeInfo(fn_type.return_type.?)) {
                .error_union => try @call(.always_inline, callable, system_ptr ++ args),
                else => @call(.always_inline, callable, system_ptr ++ args),
            }
        }
        const ns = timer.read();

        const result = try m.debug_ui.profiling_system_m_map.getOrPut(routine_name);

        if (!result.found_existing) result.value_ptr.* = .{};

        result.value_ptr.push(ns, m.time.timer_main.read());
    } else {
        const t = tracy.traceNamed(@src(), routine_name);
        defer t.end();
        try callable(system_ptr, &m.base);
    }
}
