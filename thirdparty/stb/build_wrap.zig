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
) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "stb",
        .optimize = optimize,
        .target = target,
    });

    lib.addIncludePath(.{ .path = includeDir() });
    lib.addCSourceFile(.{ .file = .{ .path = sourceFileRelative("impl.cpp", b.allocator) } });
    lib.linkLibCpp();

    return lib;
}
