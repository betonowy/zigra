const std = @import("std");

pub fn lib(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const dep_modplug = b.dependency("modplug", .{});

    const compile = b.addStaticLibrary(.{
        .optimize = optimize,
        .target = target,
        .name = "libmodplug",
        .root_source_file = b.path("thirdparty/modplug/root.zig"),
    });

    compile.linkLibC();
    compile.linkLibCpp();

    compile.addIncludePath(b.path("thirdparty/modplug/include"));
    compile.addIncludePath(b.path("thirdparty/modplug/include/libmodplug"));
    compile.addIncludePath(dep_modplug.path("src"));
    compile.addIncludePath(dep_modplug.path("src/libmodplug"));

    compile.addCSourceFiles(.{
        .root = dep_modplug.path("src"),
        .files = &.{
            "fastmix.cpp",
            "load_669.cpp",
            "load_abc.cpp",
            "load_amf.cpp",
            "load_ams.cpp",
            "load_dbm.cpp",
            "load_dmf.cpp",
            "load_dsm.cpp",
            "load_far.cpp",
            "load_it.cpp",
            "load_j2b.cpp",
            "load_mdl.cpp",
            "load_med.cpp",
            "load_mid.cpp",
            "load_mod.cpp",
            "load_mt2.cpp",
            "load_mtm.cpp",
            "load_okt.cpp",
            "load_pat.cpp",
            "load_psm.cpp",
            "load_ptm.cpp",
            "load_s3m.cpp",
            "load_stm.cpp",
            "load_ult.cpp",
            "load_umx.cpp",
            "load_wav.cpp",
            "load_xm.cpp",
            "mmcmp.cpp",
            "modplug.cpp",
            "snd_dsp.cpp",
            "sndfile.cpp",
            "snd_flt.cpp",
            "snd_fx.cpp",
            "sndmix.cpp",
        },
        .flags = &.{
            "-DMODPLUG_STATIC",
            "-DNOMINMAX",
            "-D_USE_MATH_DEFINES",
            "-DHAVE_STDINT_H",
            "-DHAVE_STRINGS_H",
            "-DHAVE_SINF",
            "-fno-sanitize=undefined",
        },
    });

    return compile;
}
