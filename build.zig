const std = @import("std");
const vma = @import("thirdparty/vma/build_wrap.zig");
const stb = @import("thirdparty/stb/build_wrap.zig");

fn vulkanIncludeDir(b: *std.Build) []const u8 {
    return b.pathFromRoot("thirdparty/Vulkan-Headers/include");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_glfw = b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_vk = b.dependency("vulkan_zig", .{
        .registry = @as([]const u8, b.pathFromRoot("thirdparty/Vulkan-Docs/xml/vk.xml")),
    });

    const lib_vma = vma.build(b, target, optimize, vulkanIncludeDir(b));
    const lib_stb = stb.build(b, target, optimize);

    const lib = b.addStaticLibrary(.{
        .name = "zigra",
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib.addIncludePath(.{ .path = vma.includeDir(b) });
    lib.addIncludePath(.{ .path = stb.includeDir() });
    lib.addIncludePath(.{ .path = vulkanIncludeDir(b) });
    lib.root_module.addImport("vk", dep_vk.module("vulkan-zig"));
    lib.root_module.addImport("glfw", dep_glfw.module("mach-glfw"));
    lib.linkLibrary(lib_vma);
    lib.linkLibrary(lib_stb);

    const exe = b.addExecutable(.{
        .name = "zigra",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigra", &lib.root_module);

    b.installArtifact(exe);

    _ = b.run(&.{ "glslc", "shaders/triangle.frag", "-o", "shaders/triangle.frag.spv" });
    _ = b.run(&.{ "glslc", "shaders/triangle.vert", "-o", "shaders/triangle.vert.spv" });

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const meta_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/meta.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_meta_unit_tests = b.addRunArtifact(meta_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_meta_unit_tests.step);
}
