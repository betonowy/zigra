const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const mod = b.createModule(.{
        .link_libc = true,
        .root_source_file = b.path("thirdparty/lz4/lz4.zig"),
    });

    mod.addIncludePath(b.path("thirdparty/lz4"));
    mod.addCMacro("LZ4_STATIC_LINKING_ONLY_DISABLE_MEMORY_ALLOCATION", "");
    mod.addCMacro("LZ4HC_HEAPMODE", "0");

    mod.addCSourceFiles(.{
        .root = b.path("thirdparty/lz4/lz4/lib"),
        .files = &.{ "lz4.c", "lz4hc.c" },
        .flags = &.{
            "-fno-sanitize=undefined",
            "-DLZ4_STATIC_LINKING_ONLY_DISABLE_MEMORY_ALLOCATION",
            "-DLZ4HC_HEAPMODE=0",
        },
    });

    return mod;
}
