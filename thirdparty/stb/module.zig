const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const mod = b.createModule(.{ .link_libcpp = true });

    mod.addIncludePath(b.path("thirdparty/stb"));
    mod.addCSourceFile(.{ .file = b.path("thirdparty/stb/impl.cpp") });

    return mod;
}
