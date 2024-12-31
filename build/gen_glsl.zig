const std = @import("std");

const cell_types = @import("../modules/zigra/systems/World/sand_sim_definitions.zig").cell_types;

pub fn step(b: *std.Build) *std.Build.Step {
    const build_step = b.allocator.create(std.Build.Step) catch @panic("OOM");
    build_step.* = std.Build.Step.init(.{
        .makeFn = &make,
        .id = .custom,
        .name = "gen_glsl",
        .owner = b,
    });
    return build_step;
}

fn make(build_step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    var timer = try std.time.Timer.start();
    defer build_step.result_duration_ns = timer.read();

    const b = build_step.owner;
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    defer build_step.result_peak_rss = arena.queryCapacity();
    build_step.result_cached = true;

    if (try genLandscapeCells(b, &arena)) build_step.result_cached = false;
}

fn areContentsUpToDate(b: *std.Build, path: []const u8, contents: []const u8, allocator: std.mem.Allocator) !bool {
    const stat = b.build_root.handle.statFile(path) catch return false;

    const buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(buffer);

    const read_slice = try b.build_root.handle.readFile(path, buffer);
    return std.mem.eql(u8, contents, read_slice);
}

fn replaceIfDifferent(b: *std.Build, path: []const u8, contents: []const u8, allocator: std.mem.Allocator) !bool {
    if (try areContentsUpToDate(b, path, contents, allocator)) return false;
    try b.build_root.handle.makePath(std.fs.path.dirname(path).?);
    try b.build_root.handle.writeFile(.{ .sub_path = path, .data = contents });
    return true;
}

fn genLandscapeCells(b: *std.Build, arena: *std.heap.ArenaAllocator) !bool {
    var string = std.ArrayList(u8).init(arena.allocator());
    errdefer string.deinit();

    const T = cell_types;

    inline for (comptime std.meta.declarations(T)) |decl| {
        try string.appendSlice(std.fmt.comptimePrint(
            "#define CellType_{s} {}\n",
            .{ decl.name, comptime @field(T, decl.name).asU16() },
        ));
    }

    const path = "modules/shaders/gen/landscape/Cells.glsl";
    return replaceIfDifferent(b, path, string.items, arena.allocator());
}
