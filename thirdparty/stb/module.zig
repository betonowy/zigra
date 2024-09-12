const std = @import("std");

pub fn module(b: *std.Build, mod_utils: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .link_libc = true,
        .root_source_file = b.path("thirdparty/stb/stb.zig"),
    });

    mod.addIncludePath(b.path("thirdparty/stb"));
    mod.addCSourceFile(.{ .file = b.path("thirdparty/stb/impl.cpp") });
    mod.addCSourceFile(.{ .file = b.path("thirdparty/stb/stb/stb_vorbis.c") });
    mod.addImport("utils", mod_utils);

    return mod;
}
