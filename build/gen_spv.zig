const std = @import("std");
const gen_glsl = @import("./gen_glsl.zig");

const ShaderStep = struct {
    gen_step: ?*std.Build.Step,
    step: std.Build.Step,
};

pub fn step(b: *std.Build, opt_gen_step: ?*std.Build.Step) *ShaderStep {
    const shader_step = b.allocator.create(ShaderStep) catch @panic("OOM");

    shader_step.* = .{
        .gen_step = opt_gen_step,
        .step = std.Build.Step.init(.{
            .id = .custom,
            .makeFn = &make,
            .name = "gen_spv_zig",
            .owner = b,
        }),
    };

    if (opt_gen_step) |gen_step| shader_step.step.dependOn(gen_step);

    return shader_step;
}

pub fn module(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("modules/shaders/module.gen.zig") });
}

const Shader = struct {
    input: []const u8,
    output: []const u8,
};

fn getExtension(path: []const u8) []const u8 {
    var tokenizer = std.mem.tokenizeAny(u8, path, ".");
    var last: ?[]const u8 = null;
    while (tokenizer.next()) |slice| last = slice;
    return last orelse path;
}

fn strEqlAnyOf(lhs: []const u8, list: []const []const u8) bool {
    for (list) |rhs| if (std.mem.eql(u8, lhs, rhs)) return true;
    return false;
}

fn make(build_step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
    var timer = try std.time.Timer.start();
    const shader_step: *ShaderStep = @fieldParentPtr("step", build_step);

    defer build_step.result_duration_ns = timer.read();
    const b = build_step.owner;

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    build_step.result_cached = true;
    const dont_cache = if (shader_step.gen_step) |gen_step| !gen_step.result_cached else false;

    const shaders_path = "modules/shaders";
    var dir = try b.build_root.handle.openDir(shaders_path, .{ .iterate = true });
    defer dir.close();

    const spv_cache = b.pathJoin(&.{ b.cache_root.path.?, "spv" });
    try b.build_root.handle.makePath(spv_cache);

    var shaders = std.ArrayList(Shader).init(allocator);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        if (strEqlAnyOf(getExtension(entry.path), &.{ "frag", "vert" })) {
            try shaders.append(.{
                .input = b.pathJoin(&.{ shaders_path, entry.path }),
                .output = b.pathJoin(&.{ spv_cache, try std.mem.concat(allocator, u8, &.{ entry.path, ".spv" }) }),
            });
        }
    }

    var node = make_options.progress_node.start("glslc", shaders.items.len);
    defer node.end();

    const glslc = b.findProgram(&.{"glslc"}, &.{}) catch |err| {
        std.log.err("glslc not found", .{});
        return err;
    };

    for (shaders.items) |shader| {
        defer node.completeOne();
        // node.setUnit(try std.mem.concat(allocator, u8, &.{ ": ", shader.input }));

        const source_stat = try b.build_root.handle.statFile(shader.input);
        const opt_output_stat: ?std.fs.Dir.Stat = b.build_root.handle.statFile(shader.output) catch |err| brk: {
            switch (err) {
                error.FileNotFound => break :brk null,
                else => return err,
            }
        };

        if (!dont_cache and opt_output_stat != null and source_stat.mtime < opt_output_stat.?.mtime) continue;

        var run = std.Build.Step.Run.create(b, "glslc");
        run.addArgs(&.{ glslc, "-I", shaders_path, "--target-env=vulkan1.2", shader.input, "-o", shader.output });
        try run.step.make(make_options);

        build_step.result_cached = false;
        build_step.result_peak_rss = @max(build_step.result_peak_rss, run.step.result_peak_rss);
    }

    if (build_step.result_cached) return;

    try zigGen(b, shaders.items);
}

fn zigGen(b: *std.Build, input: []Shader) !void {
    const generated_zig_path = "modules/shaders/module.gen.zig";

    const file = try b.build_root.handle.createFile(generated_zig_path, .{});
    defer file.close();

    var tmp_buf: [256]u8 = undefined;

    try file.writeAll("// This file has been generated by the build system\n");

    for (input) |shader| {
        const spv_input_file = try b.build_root.handle.openFile(shader.output, .{});
        defer spv_input_file.close();
        var reader = std.io.bufferedReader(spv_input_file.reader());

        try std.fmt.format(file.writer(), "\npub const {s} = [_]u32{{\n", .{normalized_name(shader.input, &tmp_buf)});

        var byte_code_buf: [8]u32 = undefined;

        while (true) {
            const count = try reader.read(std.mem.asBytes(&byte_code_buf));
            if (count == 0) break;

            try file.writeAll("   ");

            for (byte_code_buf[0..@divExact(count, 4)]) |unit| try std.fmt.format(file.writer(), " 0x{x:0>8},", .{unit});

            try file.writeAll(" //\n");
        }

        try file.writeAll("};\n");
    }
}

fn normalized_name(input: []const u8, temp_buf: []u8) []const u8 {
    const basename = std.fs.path.basename(input);
    _ = std.mem.replace(u8, basename, ".", "_", temp_buf);
    return temp_buf[0..basename.len];
}
