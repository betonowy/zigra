const std = @import("std");
const builtin = @import("builtin");
const poly = @import("poly.zig");

const la = if (!builtin.is_test) @import("la") else struct {
    pub fn sqrLength(a: anytype) f32 {
        return @reduce(.Add, a * a);
    }

    pub fn length(a: anytype) f32 {
        return @sqrt(sqrLength(a));
    }

    pub fn normalize(a: anytype) @TypeOf(a) {
        return a / @as(@TypeOf(a), @splat(length(a)));
    }
};

const edge_threshold = 1.0 / 3.0;
const edge_hit_threshold = edge_threshold + 0;

pub fn isInside(kernel: @Vector(4, f32), pos: @Vector(2, f32)) bool {
    return @reduce(.Add, kernel * bilinearWeights(pos)) > edge_threshold;
}

pub fn normal(kernel: @Vector(4, f32), pos: @Vector(2, f32)) ?@Vector(2, f32) {
    const grad = gradient(kernel, pos);
    if (@reduce(.And, grad == @Vector(2, f32){ 0, 0 })) return null;
    return la.normalize(grad);
}

pub fn gradient(kernel: @Vector(4, f32), pos: @Vector(2, f32)) @Vector(2, f32) {
    const k = kernel;
    return .{
        (1 - pos[1]) * (k[0] - k[1]) + pos[1] * (k[2] - k[3]),
        (1 - pos[0]) * (k[0] - k[2]) + pos[0] * (k[1] - k[3]),
    };
}

fn bilinearWeights(pos: @Vector(2, f32)) @Vector(4, f32) {
    const x: @Vector(4, f32) = .{ 1 - pos[0], pos[0], 1 - pos[0], pos[0] };
    const y: @Vector(4, f32) = .{ 1 - pos[1], 1 - pos[1], pos[1], pos[1] };
    return x * y;
}

pub const Intersection = union(enum) {
    hit: @Vector(2, f32),
    inside: void,
    inside_trivial: void,
    outside: void,
    outside_trivial: void,
};

pub fn intersection(k: @Vector(4, f32), pos: @Vector(2, f32), dir: @Vector(2, f32)) Intersection {
    if (getSimpleCase(k)) |case| return switch (case) {
        .inside => .inside_trivial,
        .outside => .outside_trivial,
    };

    if (@abs(dir[0]) < @abs(dir[1])) {
        const result = intersectImpl(swapDim2x2(k), swapDim2(pos), swapDim2(dir));

        return switch (result) {
            .hit => |v| .{ .hit = swapDim2(v) },
            else => result,
        };
    }

    return intersectImpl(k, pos, dir);
}

fn swapDim2(v: @Vector(2, f32)) @Vector(2, f32) {
    return @shuffle(f32, v, v, [_]i32{ 1, 0 });
}

fn swapDim2x2(v: @Vector(4, f32)) @Vector(4, f32) {
    return @shuffle(f32, v, v, [_]i32{ 0, 2, 1, 3 });
}

const Side = enum { inside, outside };

const kernel_null = @Vector(4, f32){ 0, 0, 0, 0 };
const kernel_full = @Vector(4, f32){ 1, 1, 1, 1 };

fn getSimpleCase(kernel: @Vector(4, f32)) ?Side {
    if (@reduce(.And, kernel == kernel_null)) return .outside;
    if (@reduce(.And, kernel == kernel_full)) return .inside;
    return null;
}

fn intersectImpl(k: @Vector(4, f32), pos: @Vector(2, f32), dir: @Vector(2, f32)) Intersection {
    const line = poly.Line.init(pos, dir);

    const intersectionFunction = poly.Quadratic{
        .a = line.a * (k[0] - k[1] - k[2] + k[3]),
        .b = line.b * (k[0] - k[1] - k[2] + k[3]) + line.a * (k[2] - k[0]) + k[1] - k[0],
        .c = line.b * (k[2] - k[0]) + k[0] - edge_hit_threshold,
    };

    const roots = intersectionFunction.roots() orelse return noIntersection(k, pos);

    const root = switch ((dir[0] > 0 and roots[0] >= pos[0]) or (dir[0] < 0 and roots[1] > pos[0])) {
        true => roots[0],
        false => roots[1],
    };

    const hit: @Vector(2, f32) = .{ root, line.value(root) };

    if (@reduce(.Add, (hit - pos) * dir) < 0) {
        // std.log.info("Hit behind: {}", .{hit});
        return noIntersection(k, pos);
    }

    if ((hit[0] < 0 or hit[0] > 1 or hit[1] < 0 or hit[1] > 1)) {
        // std.log.info("Hit outside: {}, r1: {}, r2: {}", .{ hit, @Vector(2, f32){ roots[0], line.value(roots[0]) }, @Vector(2, f32){ roots[1], line.value(roots[1]) } });
        return noIntersection(k, pos);
    }

    return .{ .hit = hit };
}

fn noIntersection(kernel: @Vector(4, f32), pos: @Vector(2, f32)) Intersection {
    return if (isInside(kernel, pos)) .{ .inside = {} } else .{ .outside = {} };
}

test "trivial_case_null" {
    const k = kernel_null;

    try std.testing.expectEqual(.outside, getSimpleCase(k).?);
    try std.testing.expect(!isInside(k, .{ 0, 0 }));
    try std.testing.expectEqual(.{ 0, 0 }, gradient(k, .{ 0, 0 }));
    try std.testing.expectEqual(null, normal(k, .{ 0, 0 }));

    try std.testing.expectEqualDeep(
        Intersection{ .outside_trivial = {} },
        intersection(k, .{ 0, 0 }, .{ 1, 1 }),
    );
}

test "trivial_case_full" {
    const k = kernel_full;
    const pos = @Vector(2, f32){ 0.3, 0.4 };

    try std.testing.expectEqual(.inside, getSimpleCase(k).?);
    try std.testing.expect(isInside(k, .{ 0, 0 }));
    try std.testing.expectEqual(.{ 0, 0 }, gradient(k, .{ 0, 0 }));
    try std.testing.expectEqual(null, normal(k, .{ 0, 0 }));

    try std.testing.expectEqualDeep(
        Intersection{ .inside_trivial = {} },
        intersection(k, pos, .{ 1, 1 }),
    );
}

const epsilon = 1e-5;

test "one_cell_ul_miss" {
    const k = @Vector(4, f32){ 1, 0, 0, 0 };
    const pos = @Vector(2, f32){ 0.9, 0.2 };
    const dir = @Vector(2, f32){ 0.3, -0.9 };

    try std.testing.expectEqual(null, getSimpleCase(k));
    try std.testing.expect(!isInside(k, pos));

    try std.testing.expectEqualDeep(
        Intersection{ .outside = {} },
        intersection(k, pos, dir),
    );

    const g = gradient(k, pos);
    const n = normal(k, pos).?;

    try std.testing.expectApproxEqAbs(0.8, g[0], epsilon);
    try std.testing.expectApproxEqAbs(0.1, g[1], epsilon);
    try std.testing.expectApproxEqAbs(0.99228, n[0], epsilon);
    try std.testing.expectApproxEqAbs(0.12403, n[1], epsilon);
}

test "one_cell_ul_hits_in_bounds" {
    const k = @Vector(4, f32){ 1, 0, 0, 0 };
    const pos = @Vector(2, f32){ 0.7, 0.8 };
    const dir = @Vector(2, f32){ -0.3, -0.9 };

    try std.testing.expectEqual(null, getSimpleCase(k));
    try std.testing.expect(!isInside(k, pos));

    const result = intersection(k, pos, dir);
    try std.testing.expectApproxEqAbs(0.53017, result.hit[0], epsilon);
    try std.testing.expectApproxEqAbs(0.29052, result.hit[1], epsilon);

    const g = gradient(k, result.hit);
    const n = normal(k, result.hit).?;

    try std.testing.expectApproxEqAbs(0.70948, g[0], epsilon);
    try std.testing.expectApproxEqAbs(0.46983, g[1], epsilon);
    try std.testing.expectApproxEqAbs(0.83376, n[0], epsilon);
    try std.testing.expectApproxEqAbs(0.55213, n[1], epsilon);
}

test "regression_001" {
    {
        const result = intersection(.{ 0, 1, 0, 1 }, .{ 3.19065093e-01, -1 }, .{ 6.48091614e-01, -7.61562407e-01 });
        std.debug.print("result: {}\n", .{result});
    }
    {
        const result = intersection(.{ 0, 1, 0, 1 }, .{ 3.19065093e-01, -1 }, .{ 6.50e-01, -7.61562407e-01 });
        std.debug.print("result: {}\n", .{result});
    }
}
