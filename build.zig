const std = @import("std");
const vma = @import("thirdparty/vma/build_wrap.zig");
const stb = @import("thirdparty/stb/build_wrap.zig");

const shaders = @import("steps/shaders.zig");

fn vulkanIncludeDir(b: *std.Build) []const u8 {
    return b.pathFromRoot("thirdparty/Vulkan-Headers/include");
}

pub fn build(b: *std.Build) !void {
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
    const compile_glsl_step = shaders.step(b);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    exe.step.dependOn(compile_glsl_step);

    if (b.args) |args| run_cmd.addArgs(args);

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

    const vulkan_types_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/vulkan_types.zig" },
        .target = target,
        .optimize = optimize,
    });

    const vulkan_atlas_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/VulkanAtlas.zig" },
        .target = target,
        .optimize = optimize,
    });

    const vulkan_landscape_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/VulkanLandscape.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_meta_unit_tests = b.addRunArtifact(meta_tests);
    const run_vulkan_types_unit_tests = b.addRunArtifact(vulkan_types_tests);
    const run_vulkan_atlas_unit_tests = b.addRunArtifact(vulkan_atlas_tests);
    const run_vulkan_landscape_unit_tests = b.addRunArtifact(vulkan_landscape_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_meta_unit_tests.step);
    test_step.dependOn(&run_vulkan_types_unit_tests.step);
    test_step.dependOn(&run_vulkan_atlas_unit_tests.step);
    test_step.dependOn(&run_vulkan_landscape_unit_tests.step);
}
