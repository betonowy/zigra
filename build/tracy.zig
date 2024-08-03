const std = @import("std");

pub fn module(
    b: *std.Build,
    options: struct {
        enable_tracy: bool,
        enable_allocator: bool,
        enable_callstack: bool,
        target: std.Build.ResolvedTarget,
    },
) *std.Build.Module {
    const tracy_options = b.addOptions();
    tracy_options.addOption(bool, "enable", options.enable_tracy);
    tracy_options.addOption(bool, "enable_allocation", options.enable_tracy and options.enable_allocator);
    tracy_options.addOption(bool, "enable_callstack", options.enable_tracy and options.enable_callstack);

    const mod = b.addModule("tracy", .{
        .root_source_file = b.path("modules/tracy/root.zig"),
        .link_libc = true,
        .link_libcpp = true,
    });

    mod.addImport("options", tracy_options.createModule());

    const dep_tracy = b.dependency("tracy", .{});
    mod.addIncludePath(dep_tracy.path("public"));

    const tracy_c_flags: []const []const u8 = if (options.target.result.isMinGW())
        &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
    else
        &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

    mod.addCSourceFile(.{ .file = dep_tracy.path("public/TracyClient.cpp"), .flags = tracy_c_flags });

    if (options.target.result.os.tag == .windows) {
        mod.linkSystemLibrary("dbghelp", .{});
        mod.linkSystemLibrary("ws2_32", .{});
    }

    return mod;
}
