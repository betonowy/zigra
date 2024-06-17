const std = @import("std");
const vma = @import("thirdparty/vma/build_wrap.zig");
const stb = @import("thirdparty/stb/build_wrap.zig");
const nuklear = @import("thirdparty/nuklear/build_wrap.zig");

const shaders = @import("steps/shaders.zig");
const glsl_gen = @import("steps/glsl_gen.zig");

const vulkan_headers_include_dir = "thirdparty/Vulkan-Headers/include";
const vulkan_docs_xml_path = "thirdparty/Vulkan-Docs/xml/vk.xml";

const files_to_test = [_][]const u8{
    "src/root.zig",
    "src/meta.zig",
    "src/vulkan_types.zig",
    "src/VulkanAtlas.zig",
    "src/VulkanLandscape.zig",
    "src/LandscapeSim.zig",
    "src/lifetime.zig",
};

fn vulkanIncludeDir(b: *std.Build) []const u8 {
    return b.pathFromRoot(vulkan_headers_include_dir);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profiling = b.option(bool, "profiling", "Enable profiling features.");
    const debug_ui = b.option(bool, "debug-ui", "Enable debug ui tools.");

    const build_options = b.addOptions();
    build_options.addOption(bool, "profiling", profiling orelse false);
    build_options.addOption(bool, "debug_ui", debug_ui orelse false);
    build_options.addOption(usize, "world_tile_size", 128);
    build_options.addOption(usize, "gfx_max_commands", 65536);
    const build_options_module = build_options.createModule();

    const dep_glfw = b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_stb = stb.build(b, target, optimize);
    const mod_nuklear = nuklear.build(b, target, optimize);

    const lib = b.addStaticLibrary(.{
        .name = "zigra",
        .root_source_file = .{ .path = "src/zigra.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib.addIncludePath(.{ .path = stb.includeDir() });
    lib.addIncludePath(.{ .path = vulkanIncludeDir(b) });
    lib.root_module.addImport("glfw", dep_glfw.module("mach-glfw"));
    lib.root_module.addImport("options", build_options_module);
    lib.root_module.addImport("nuklear", mod_nuklear);
    lib.linkLibrary(lib_stb);

    const exe = b.addExecutable(.{
        .name = "zigra",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const gen_glsl_step = glsl_gen.step(b);
    const compile_glsl_step = shaders.step(b, gen_glsl_step);
    exe.step.dependOn(&compile_glsl_step.step);

    exe.root_module.addImport("zigra", &lib.root_module);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    createTestStep(b, target, optimize, build_options_module);
}

fn makeTestName(comptime str: []const u8) [str.len - 4]u8 {
    var new_str: [str.len - 4]u8 = undefined;
    @memcpy(new_str[0..], str[0 .. str.len - 4]);

    for (new_str[0..]) |*c| c.* = switch (c.*) {
        ' ' => '_',
        '/', '\\', ':' => '.',
        else => c.*,
    };

    return new_str;
}

fn createTestStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Mode, options_module: *std.Build.Module) void {
    const step = b.step("test", "Run unit tests");

    inline for (files_to_test) |path| {
        const name = comptime makeTestName("test " ++ path);

        const compile_test = b.addTest(.{
            .name = &name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = optimize,
        });

        compile_test.root_module.addImport("options", options_module);

        const run_test = b.addRunArtifact(compile_test);
        const install_test = b.addInstallArtifact(compile_test, .{ .dest_dir = .{ .override = .{ .custom = "test" } } });

        step.dependOn(&run_test.step);
        step.dependOn(&install_test.step);
    }
}
