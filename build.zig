const std = @import("std");

const stb = @import("thirdparty/stb/build_wrap.zig");
const nuklear = @import("thirdparty/nuklear/build_wrap.zig");
const lz4 = @import("thirdparty/lz4/build_wrap.zig");

const shaders = @import("steps/shaders.zig");
const glsl_gen = @import("steps/glsl_gen.zig");

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

    const mod_stb = stb.build(b);
    const mod_nuklear = nuklear.build(b);
    const mod_lz4 = lz4.build(b);

    const mod_utils = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "utils/root.zig" },
    });

    const mod_zigra = b.addModule("zigra", .{
        .root_source_file = .{ .path = "src/zigra.zig" },
        .target = target,
        .optimize = optimize,
    });

    mod_zigra.addIncludePath(.{ .path = stb.includeDir() });
    mod_zigra.addImport("glfw", dep_glfw.module("mach-glfw"));
    mod_zigra.addImport("options", build_options_module);
    mod_zigra.addImport("nuklear", mod_nuklear);
    mod_zigra.addImport("utils", mod_utils);
    mod_zigra.addImport("lz4", mod_lz4);
    mod_zigra.addImport("stb", mod_stb);

    const exe = b.addExecutable(.{
        .name = "zigra",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const gen_glsl_step = glsl_gen.step(b);
    const compile_glsl_step = shaders.step(b, gen_glsl_step);
    exe.step.dependOn(&compile_glsl_step.step);

    exe.root_module.addImport("zigra", mod_zigra);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
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
