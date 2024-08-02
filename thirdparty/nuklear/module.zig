const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const nuklear = b.createModule(.{
        .link_libc = true,
        .root_source_file = b.path("thirdparty/nuklear/nuklear.zig"),
    });

    nuklear.addIncludePath(b.path("thirdparty/nuklear"));
    nuklear.addCSourceFile(.{ .file = b.path("thirdparty/nuklear/impl.c") });

    return nuklear;
}
