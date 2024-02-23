const std = @import("std");

pub fn step(b: *std.Build) *std.Build.Step {
    var build_step = b.step("shaders", "Compile vulkan shaders");
    build_step.makeFn = &make;
    return build_step;
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

fn make(build_step: *std.Build.Step, parent_node: *std.Progress.Node) anyerror!void {
    var timer = try std.time.Timer.start();
    defer build_step.result_duration_ns = timer.read();
    const b = build_step.owner;
    const cwd = std.fs.cwd();

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    build_step.result_cached = true;

    const shaders_path = "shaders";
    var dir = try cwd.openDir(shaders_path, .{ .iterate = true });
    defer dir.close();

    var shaders = std.ArrayList(Shader).init(allocator);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        if (strEqlAnyOf(getExtension(entry.path), &.{ "frag", "vert" })) {
            try shaders.append(.{
                .input = b.pathJoin(&.{ shaders_path, entry.path }),
                .output = b.pathJoin(&.{ shaders_path, try std.mem.concat(allocator, u8, &.{ entry.path, ".spv" }) }),
            });
        }
    }

    var node = parent_node.start("glslc", shaders.items.len);
    defer node.end();

    const glslc = b.findProgram(&.{"glslc"}, &.{}) catch |err| {
        std.log.err("glslc not found", .{});
        return err;
    };

    for (shaders.items) |shader| {
        defer node.completeOne();
        node.setUnit(try std.mem.concat(allocator, u8, &.{ ": ", shader.input }));

        const source_stat = try cwd.statFile(shader.input);
        const opt_output_stat: ?std.fs.Dir.Stat = cwd.statFile(shader.output) catch |err| brk: {
            switch (err) {
                error.FileNotFound => break :brk null,
                else => return err,
            }
        };

        if (opt_output_stat != null and source_stat.mtime < opt_output_stat.?.mtime) continue;

        var run = std.Build.Step.Run.create(b, "glslc");
        run.addArgs(&.{ glslc, "-I", shaders_path, "--target-env=vulkan1.2", shader.input, "-o", shader.output });
        try run.step.make(&node);

        build_step.result_cached = false;
        build_step.result_peak_rss = @max(build_step.result_peak_rss, run.step.result_peak_rss);
    }
}
