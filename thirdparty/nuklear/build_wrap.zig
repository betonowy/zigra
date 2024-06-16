const std = @import("std");

fn sourceFileRelative(path: []const u8, allocator: std.mem.Allocator) []const u8 {
    const base = std.fs.path.dirname(@src().file) orelse unreachable;
    return std.fs.path.join(allocator, &.{ base, path }) catch unreachable;
}

pub fn includeDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const nuklear = b.addModule("nuklear", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = .{ .path = sourceFileRelative("nuklear.zig", b.allocator) },
    });

    nuklear.addIncludePath(.{ .path = includeDir() });
    nuklear.addCSourceFile(.{ .file = .{ .path = sourceFileRelative("impl.c", b.allocator) } });

    return nuklear;
}
