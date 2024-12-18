const std = @import("std");
const builtin = @import("builtin");

/// Will panic if error union contains an error. No stacktrace.
pub fn unwrap(retVal: anytype) @typeInfo(@TypeOf(retVal)).ErrorUnion.payload {
    return retVal catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unwrapped {s}, panicking.", .{@errorName(err)}) catch {
            std.log.err("Unwrapped {s}", .{@errorName(err)});
            @panic("Panicking.");
        };
        @panic(msg);
    };
}

/// Prints error name and stacktrace (if available) and panics.
pub fn panic(err: anyerror, trace_opt: ?*std.builtin.StackTrace) noreturn {
    std.log.err("{s}", .{@errorName(err)});
    if (trace_opt) |trace| std.debug.dumpStackTrace(trace.*);
    @panic("Panicking.");
}

pub fn UnwrappedCallReturnType(Fn: type) type {
    const BaseReturnType = @typeInfo(Fn).Fn.return_type.?;
    return switch (@typeInfo(BaseReturnType)) {
        .ErrorUnion => |eu| eu.payload,
        else => @compileError("Return type must be an error union."),
    };
}

/// Calls function with args. If return value contains an error,
/// prints error name and stacktrace (if available) and panics.
pub fn call(func: anytype, args: anytype) UnwrappedCallReturnType(@TypeOf(func)) {
    return @call(.auto, func, args) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        @panic("Can't return an error. Panicking.");
    };
}

pub fn breakIfDebuggerPresent() void {
    if (isDebuggerPresent()) @breakpoint();
}

pub fn isDebuggerPresent() bool {
    switch (builtin.os.tag) {
        .windows => {
            const winapi = struct {
                pub extern "kernel32" fn IsDebuggerPresent() callconv(.winapi) std.os.windows.BOOL;
            };
            return winapi.IsDebuggerPresent() != std.os.windows.FALSE;
        },
        .linux => {
            var buf: [4096]u8 = undefined;
            const slice = std.fs.cwd().readFile("/proc/self/status", &buf) catch return false;

            const entry_name = "TracerPid:";
            const index_of_entry = std.mem.indexOf(u8, slice, entry_name) orelse return false;
            const slice_start = slice[index_of_entry + entry_name.len ..];
            const index_of_newline = std.mem.indexOfScalar(u8, slice_start, '\n') orelse return false;
            const entry = slice_start[0..index_of_newline];
            const number_start = std.mem.indexOfNone(u8, entry, " \t") orelse return false;
            const pid = std.fmt.parseInt(usize, entry[number_start..], 10) catch return false;

            return pid != 0;
        },
        else => return false,
    }
}
