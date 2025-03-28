const std = @import("std");

const gen_spv = @import("build/gen_spv.zig");
const gen_glsl = @import("build/gen_glsl.zig");
const tracy_profiler = @import("build/tracy.zig");
const thirdparty = @import("thirdparty/modules.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "Use LLVM backend. (default: true)");
    const tracy = b.option(bool, "tracy", "Enable tracy-profiler integration. (default: false)");
    const profiling = b.option(bool, "profiling", "Enable in-app profiling. (default: false)");
    const debug_ui = b.option(bool, "debug-ui", "Enable debug-ui tools. (default: false)");
    const lock_tick = b.option(bool, "lock-tick", "Locks 1 tick per frame. (default: false)");
    const lock_fps = b.option(f32, "lock-fps", "Limits FPS to this limit. (default: null)");
    const test_filter = b.option([]const u8, "test-filter", "Run/install only [name] test. (default: runs/installs all tests)");
    const thread_sanitizer = b.option(bool, "tsan", "Enable thread sanitizer");
    const ensure_debug_info = b.option(bool, "ensure-debug-info", "Ensures debug info is in the executable");

    const options = b.addOptions();
    options.addOption(bool, "profiling", profiling orelse false);
    options.addOption(bool, "debug_ui", debug_ui orelse false);
    options.addOption(bool, "lock_tick", lock_tick orelse false);
    options.addOption(?f32, "lock_fps", lock_fps orelse null);

    const dep_glfw = b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
    });

    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    const vk_registry_xml = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    vk_generate_cmd.addFileArg(vk_registry_xml);
    const mod_vk = b.createModule(.{ .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig") });

    const mod_tracy = tracy_profiler.module(b, .{
        .enable_tracy = tracy orelse false,
        .enable_allocator = false,
        .enable_callstack = false,
        .target = target,
    });

    const mod_la = b.createModule(.{ .root_source_file = b.path("modules/la/root.zig") });
    const mod_util = b.createModule(.{ .root_source_file = b.path("modules/util/root.zig") });
    mod_util.addImport("la", mod_la);
    const mod_zvk = b.createModule(.{ .root_source_file = b.path("modules/zvk/root.zig") });
    mod_zvk.addImport("vk", mod_vk);
    mod_zvk.addImport("util", mod_util);
    mod_zvk.addImport("la", mod_la);

    const mod_options = options.createModule();
    const mod_stb = thirdparty.stb.module(b, mod_util);
    const mod_nuklear = thirdparty.nuklear.module(b);
    const mod_lz4 = thirdparty.lz4.module(b);

    const mod_enet = b.createModule(.{ .root_source_file = b.path("modules/enet/root.zig"), .link_libc = false });
    mod_enet.addCSourceFile(.{ .file = b.path("modules/enet/enet.c"), .flags = &.{"-fno-sanitize=undefined"} });
    mod_enet.addIncludePath(b.dependency("zpl_enet", .{}).path("include"));
    mod_enet.addImport("lz4", mod_lz4);

    const dep_zaudio = b.dependency("zaudio", .{
        .optimize = optimize,
        .target = target,
    });

    const mod_zaudio = dep_zaudio.module("root");
    mod_zaudio.linkLibrary(dep_zaudio.artifact("miniaudio"));

    const mod_lifetime = b.createModule(.{ .root_source_file = b.path("modules/lifetime/lifetime.zig") });
    mod_lifetime.addImport("tracy", mod_tracy);
    mod_lifetime.addImport("options", mod_options);

    const lib_modplug = thirdparty.modplug.lib(b, optimize, target);

    const step_gen_glsl = gen_glsl.step(b);
    const step_gen_spv = gen_spv.step(b, step_gen_glsl);
    const mod_spv = gen_spv.module(b);

    const mod_zigra = b.createModule(.{ .root_source_file = b.path("modules/zigra/root.zig") });
    mod_zigra.addIncludePath(b.path("thirdparty/stb"));
    mod_zigra.addImport("glfw", dep_glfw.module("glfw"));
    mod_zigra.addImport("vk", mod_vk);
    mod_zigra.addImport("options", mod_options);
    mod_zigra.addImport("nuklear", mod_nuklear);
    mod_zigra.addImport("util", mod_util);
    mod_zigra.addImport("lz4", mod_lz4);
    mod_zigra.addImport("stb", mod_stb);
    mod_zigra.addImport("lifetime", mod_lifetime);
    mod_zigra.addImport("spv", mod_spv);
    mod_zigra.addImport("la", mod_la);
    mod_zigra.addImport("tracy", mod_tracy);
    mod_zigra.addImport("enet", mod_enet);
    mod_zigra.addImport("zaudio", mod_zaudio);
    mod_zigra.addImport("zvk", mod_zvk);
    mod_zigra.addImport("modplug", lib_modplug.root_module);

    const exe = b.addExecutable(.{
        .name = "zigra",
        .root_source_file = b.path("modules/app/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
        .strip = optimize != .Debug and
            tracy != true and
            thread_sanitizer != true and
            ensure_debug_info != true,
        .sanitize_thread = thread_sanitizer orelse false,
    });

    exe.step.dependOn(&step_gen_spv.step);
    exe.root_module.addImport("zigra", mod_zigra);
    exe.root_module.addImport("util", mod_util);

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ws2_32");
        exe.linkSystemLibrary("winmm");
    }

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (thread_sanitizer == true) {
        run_cmd.setEnvironmentVariable("TSAN_OPTIONS", try std.mem.concat(b.allocator, u8, &.{
            "suppressions=",
            b.pathJoin(&.{ b.build_root.path.?, "build/tsan.supp" }),
        }));
    }

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zigra");
    run_step.dependOn(&run_cmd.step);

    const check = b.step("check", "Check build");
    check.dependOn(&exe.step);

    const test_ctx = tests.Ctx{
        .b = b,
        .step_run = tests.addParentStep(b),
        .step_install = tests.addParentInstallStep(b),
        .target = target,
        .optimize = optimize,
        .test_only = test_filter,
    };

    tests.addTest(test_ctx, "modules-la", "modules/la/root.zig", mod_la, .{ .use_llvm = use_llvm });
    tests.addTest(test_ctx, "modules-lifetime", "modules/lifetime/lifetime.zig", mod_lifetime, .{ .use_llvm = use_llvm });
    tests.addTest(test_ctx, "modules-util", "modules/util/root.zig", mod_util, .{ .tsan = thread_sanitizer, .use_llvm = use_llvm });
    tests.addTest(test_ctx, "modules-zigra", "modules/zigra/root.zig", mod_zigra, .{ .use_llvm = use_llvm });
    tests.addTest(test_ctx, "thirdparty-lz4", "thirdparty/lz4/lz4.zig", mod_lz4, .{ .use_llvm = use_llvm });
    tests.addTest(test_ctx, "modules-enet", "modules/enet/root.zig", mod_enet, .{ .use_llvm = use_llvm });
}
