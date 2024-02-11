const std = @import("std");

fn sourceFileRelative(path: []const u8, allocator: std.mem.Allocator) []const u8 {
    const base = std.fs.path.dirname(@src().file) orelse unreachable;
    return std.fs.path.join(allocator, &.{ base, path }) catch unreachable;
}

pub fn includeDir(b: *std.Build) []const u8 {
    return sourceFileRelative("VulkanMemoryAllocator/include", b.allocator);
}

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include_dir: []const u8,
) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "vma",
        .optimize = optimize,
        .target = target,
    });

    lib.addIncludePath(.{ .path = includeDir(b) });
    lib.addIncludePath(.{ .path = vulkan_include_dir });
    lib.addCSourceFile(.{ .file = .{ .path = sourceFileRelative("impl.cpp", b.allocator) } });
    lib.linkLibCpp();

    return lib;
}
