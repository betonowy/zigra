const std = @import("std");

const thirdparty = @import("thirdparty/modules.zig");

const gen_spv = @import("build/gen_spv.zig");
const gen_glsl = @import("build/gen_glsl.zig");
const options = @import("build/options.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_glfw = b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
    });

    const mod_options = options.module(b);
    const mod_stb = thirdparty.stb.module(b);
    const mod_nuklear = thirdparty.nuklear.module(b);
    const mod_lz4 = thirdparty.lz4.module(b);

    const mod_la = b.createModule(.{ .root_source_file = .{ .path = "modules/la/root.zig" } });
    const mod_utils = b.createModule(.{ .root_source_file = .{ .path = "modules/utils/root.zig" } });
    const mod_lifetime = b.createModule(.{ .root_source_file = .{ .path = "modules/lifetime/lifetime.zig" } });
    mod_lifetime.addImport("options", mod_options);

    const step_gen_glsl = gen_glsl.step(b);
    const step_gen_spv = gen_spv.step(b, step_gen_glsl);
    const mod_spv = gen_spv.module(b);

    const mod_zigra = b.createModule(.{ .root_source_file = .{ .path = "modules/zigra/root.zig" } });
    mod_zigra.addIncludePath(.{ .path = thirdparty.stb.includeDir() });
    mod_zigra.addImport("glfw", dep_glfw.module("mach-glfw"));
    mod_zigra.addImport("options", mod_options);
    mod_zigra.addImport("nuklear", mod_nuklear);
    mod_zigra.addImport("utils", mod_utils);
    mod_zigra.addImport("lz4", mod_lz4);
    mod_zigra.addImport("stb", mod_stb);
    mod_zigra.addImport("lifetime", mod_lifetime);
    mod_zigra.addImport("spv", mod_spv);
    mod_zigra.addImport("la", mod_la);

    const exe = b.addExecutable(.{
        .name = "zigra",
        .root_source_file = .{ .path = "modules/app/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(&step_gen_spv.step);
    exe.root_module.addImport("zigra", mod_zigra);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
