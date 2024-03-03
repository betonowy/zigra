const std = @import("std");

const cell_types = @import("../src/landscape_cell_types.zig").cell_types;
const types = @import("../src/vulkan_types.zig");

pub fn step(b: *std.Build) *std.Build.Step {
    var build_step = b.step("glsl_gen", "Generate glsl code");
    build_step.makeFn = &make;
    return build_step;
}

fn make(build_step: *std.Build.Step, parent_node: *std.Progress.Node) anyerror!void {
    var timer = try std.time.Timer.start();
    defer build_step.result_duration_ns = timer.read();

    const b = build_step.owner;
    var node = parent_node.start("generating", 0);

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    defer build_step.result_peak_rss = arena.queryCapacity();
    build_step.result_cached = true;

    if (try genPushConstant(b, types.BasicPushConstant, &arena, &node)) build_step.result_cached = false;
    if (try genLandscapeCells(b, &arena, &node)) build_step.result_cached = false;
}

const GlslField = struct {
    name: []const u8,
    type: []const u8,
};

fn simpleGlslName(comptime T: type) []const u8 {
    return switch (T) {
        u32 => "uint",
        i32 => "int",
        f32 => "float",
        else => unreachable,
    };
}

fn digitToStr(digit: u8) [1]u8 {
    return .{std.fmt.digitToChar(digit, .lower)};
}

fn vectorGlslName(comptime v: std.builtin.Type.Vector) []const u8 {
    if (v.len < 2 or v.len > 4) @compileError("Vector size must be between 2 and 4");

    if (@sizeOf(v.child) == 4) {
        return switch (v.child) {
            u32 => "uvec" ++ digitToStr(v.len),
            i32 => "ivec" ++ digitToStr(v.len),
            f32 => "vec" ++ digitToStr(v.len),
            else => unreachable,
        };
    }

    return "";
}

fn toGlslTypeName(comptime T: type) []const u8 {
    comptime std.debug.assert(@alignOf(T) >= 4);

    return switch (@typeInfo(T)) {
        .Type => simpleGlslName(T),
        .Vector => |v| vectorGlslName(v),
        else => unreachable,
    };
}

fn toGlslFields(comptime T: type) ![std.meta.fields(T).len]GlslField {
    comptime {
        const src_names = std.meta.fieldNames(T);
        const src_fields = std.meta.fields(T);
        var dst_fields: [std.meta.fields(T).len]GlslField = undefined;

        for (src_names, src_fields, dst_fields[0..]) |src_name, _, *glsl| {
            glsl.type = toGlslTypeName(@TypeOf(@field(std.mem.zeroes(T), src_name)));
            glsl.name = src_name;
        }

        return dst_fields;
    }
}

fn appendFields(comptime T: type, string: *std.ArrayList(u8)) !void {
    inline for (comptime try toGlslFields(T)) |field| {
        try string.appendSlice(std.fmt.comptimePrint("    {s} {s};\n", .{ field.type, field.name }));
    }
}

fn typeNameExtract(comptime T: type) []const u8 {
    comptime {
        var tokenizer = std.mem.tokenizeAny(u8, @typeName(T), ".");
        var last: ?[]const u8 = null;
        while (tokenizer.next()) |slice| last = slice;
        return last.?;
    }
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
    try b.build_root.handle.writeFile2(.{ .sub_path = path, .data = contents });
    return true;
}

fn genPushConstant(b: *std.Build, comptime T: type, arena: *std.heap.ArenaAllocator, node: *std.Progress.Node) !bool {
    var string = std.ArrayList(u8).init(arena.allocator());
    errdefer string.deinit();
    defer node.completeOne();

    try string.appendSlice("layout(push_constant, std430) uniform PushConstant {\n");
    try appendFields(T, &string);
    try string.appendSlice("} pc;\n");

    try b.build_root.handle.makePath("src/shaders/gen/pc");

    const path = try std.fs.path.join(
        arena.allocator(),
        &.{ "src/shaders/gen/pc", comptime typeNameExtract(T) ++ ".glsl" },
    );

    return replaceIfDifferent(b, path, string.items, arena.allocator());
}

fn genLandscapeCells(b: *std.Build, arena: *std.heap.ArenaAllocator, node: *std.Progress.Node) !bool {
    var string = std.ArrayList(u8).init(arena.allocator());
    errdefer string.deinit();
    defer node.completeOne();

    const T = cell_types;

    inline for (comptime std.meta.declarations(T)) |decl| {
        try string.appendSlice(std.fmt.comptimePrint(
            "#define CellType_{s} {}\n",
            .{ decl.name, comptime @field(T, decl.name).asU8() },
        ));
    }

    const path = "src/shaders/gen/landscape/Cells.glsl";
    return replaceIfDifferent(b, path, string.items, arena.allocator());
}
