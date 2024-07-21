const std = @import("std");

fn sourceFileRelative(path: []const u8, allocator: std.mem.Allocator) []const u8 {
    const base = std.fs.path.dirname(@src().file) orelse unreachable;
    return std.fs.path.join(allocator, &.{ base, path }) catch unreachable;
}

pub fn includeDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

pub fn build(b: *std.Build) *std.Build.Module {
    const mod = b.addModule("stb", .{ .link_libcpp = true });

    mod.addIncludePath(.{ .path = includeDir() });
    mod.addCSourceFile(.{ .file = .{ .path = sourceFileRelative("impl.cpp", b.allocator) } });

    return mod;
}
