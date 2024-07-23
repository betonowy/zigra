const std = @import("std");

fn sourceFileRelative(b: *std.Build, path: []const u8) []const u8 {
    const base = std.fs.path.dirname(@src().file) orelse unreachable;
    return b.pathJoin(&.{ base, path });
}

fn includeDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

fn lz4Cfg(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(.{ .path = includeDir() });
    mod.addCMacro("LZ4HC_HEAPMODE", "0");
    mod.addCSourceFiles(.{
        .root = .{ .path = sourceFileRelative(b, "lz4/lib") },
        .files = &.{ "lz4.c", "lz4hc.c" },
    });
}

pub fn module(b: *std.Build) *std.Build.Module {
    const mod = b.createModule(.{
        .link_libc = true,
        .root_source_file = .{ .path = sourceFileRelative(b, "lz4.zig") },
    });

    const test_exe = b.addTest(.{
        .name = "test-lz4",
        .root_source_file = .{ .path = sourceFileRelative(b, "lz4.zig") },
        .link_libc = true,
    });

    lz4Cfg(b, mod);
    lz4Cfg(b, &test_exe.root_module);

    b.step("test-lz4", "Test thirdparty/lz4 module")
        .dependOn(&b.addRunArtifact(test_exe).step);

    return mod;
}
