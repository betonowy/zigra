const std = @import("std");

pub fn addParentStep(b: *std.Build) *std.Build.Step {
    return b.step("test", "Perform all tests");
}

pub fn addParentInstallStep(b: *std.Build) *std.Build.Step {
    return b.step("test-install", "Install all tests");
}

pub const Ctx = struct { //
    b: *std.Build,
    step_run: *std.Build.Step,
    step_install: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    test_only: ?[]const u8,
};

pub fn addTest(
    ctx: Ctx,
    name: []const u8,
    file: []const u8,
    dep_source: *std.Build.Module,
    opts: struct { tsan: ?bool = null, use_llvm: ?bool = null },
) void {
    if (ctx.test_only) |match| if (!std.mem.eql(u8, match, name)) return;

    const exe = ctx.b.addTest(.{
        .name = name,
        .root_source_file = ctx.b.path(file),
        .optimize = ctx.optimize,
        .target = ctx.target,
        .sanitize_thread = opts.tsan orelse false,
        .use_llvm = opts.use_llvm orelse true,
    });

    if (dep_source.link_libc) |flag| if (flag) exe.linkLibC();
    if (dep_source.link_libcpp) |flag| if (flag) exe.linkLibCpp();

    var module_iterator = dep_source.import_table.iterator();
    while (module_iterator.next()) |mod| {
        exe.root_module.addImport(mod.key_ptr.*, mod.value_ptr.*);
        if (mod.value_ptr.*.link_libc) |flag| if (flag) exe.linkLibC();
        if (mod.value_ptr.*.link_libcpp) |flag| if (flag) exe.linkLibCpp();
    }

    for (dep_source.include_dirs.items) |include_dir| switch (include_dir) {
        .path,
        .path_system,
        .path_after,
        .framework_path,
        .framework_path_system,
        => |include_path| exe.root_module.addIncludePath(include_path),
        else => @panic("Unimplemented"),
    };

    for (dep_source.link_objects.items) |link_object| switch (link_object) {
        .c_source_file => |s| exe.addCSourceFile(.{ .file = s.file, .flags = s.flags }),
        .c_source_files => |s| exe.addCSourceFiles(.{ .files = s.files, .flags = s.flags, .root = s.root }),
        .other_step => |s| {
            if (s.root_module.link_libc) |flag| if (flag) exe.linkLibC();
            if (s.root_module.link_libcpp) |flag| if (flag) exe.linkLibCpp();
        },
        else => @panic("Unimplemented"),
    };

    const run = ctx.b.addRunArtifact(exe);
    ctx.step_run.dependOn(&run.step);

    const install = ctx.b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } });
    ctx.step_install.dependOn(&install.step);
}
