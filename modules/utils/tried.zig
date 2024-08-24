const std = @import("std");

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
