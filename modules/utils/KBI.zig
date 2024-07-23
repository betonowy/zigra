const std = @import("std");
const poly = @import("poly.zig");

const edge_threshold = 1.0 / 3.0;

kernel: @Vector(4, f32),

pub fn init(kernel: @Vector(4, f32)) @This() {
    return .{ .kernel = kernel };
}

pub fn isInside(self: @This(), pos: @Vector(2, f32)) bool {
    return @reduce(.Add, self.kernel * bilinearWeights(pos)) > edge_threshold;
}

pub fn getNormal(self: @This(), pos: @Vector(2, f32)) ?@Vector(2, f32) {
    const gradient = self.getGradient(pos);
    if (@reduce(.And, gradient == @Vector(2, f32){ 0, 0 })) return null;
    return gradient / @as(@Vector(2, f32), @splat(@sqrt(@reduce(.Add, gradient * gradient))));
}

pub fn getGradient(self: @This(), pos: @Vector(2, f32)) @Vector(2, f32) {
    const k = self.kernel;
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

pub fn getIntersection(self: @This(), pos: @Vector(2, f32), dir: @Vector(2, f32)) Intersection {
    if (self.getSimpleCase()) |case| return switch (case) {
        .inside => .inside_trivial,
        .outside => .outside_trivial,
    };

    const krn = self.kernel;

    if (@abs(dir[0]) < @abs(dir[1])) {
        const result = self.intersect(swapDim2(pos), swapDim2(dir), swapDim2x2(krn));

        return switch (result) {
            .hit => |v| .{ .hit = swapDim2(v) },
            else => result,
        };
    }

    return self.intersect(pos, dir, krn);
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

fn getSimpleCase(self: @This()) ?Side {
    if (allOf(self.kernel == kernel_null)) return .outside;
    if (allOf(self.kernel == kernel_full)) return .inside;
    return null;
}

fn intersect(self: @This(), pos: @Vector(2, f32), dir: @Vector(2, f32), k: @Vector(4, f32)) Intersection {
    const line = poly.Line.init(pos, dir);

    const intersectionFunction = poly.Quadratic{
        .a = line.a * (k[0] - k[1] - k[2] + k[3]),
        .b = line.b * (k[0] - k[1] - k[2] + k[3]) + line.a * (k[2] - k[0]) + k[1] - k[0],
        .c = line.b * (k[2] - k[0]) + k[0] - edge_threshold,
    };

    const roots = intersectionFunction.roots() orelse return self.noIntersection(pos);

    const root = switch ((dir[0] > 0 and roots[0] >= pos[0]) or (dir[0] < 0 and roots[1] > pos[0])) {
        true => roots[0],
        false => roots[1],
    };

    const hit: @Vector(2, f32) = .{ root, line.value(root) };

    if ((hit[0] < 0 or hit[0] > 1 or hit[1] < 0 or hit[1] > 1) or (dot(hit - pos, dir) < 0)) {
        return self.noIntersection(pos);
    }

    return .{ .hit = hit };
}

fn noIntersection(self: @This(), pos: @Vector(2, f32)) Intersection {
    return if (self.isInside(pos)) .{ .inside = {} } else .{ .outside = {} };
}

fn dot(a: @Vector(2, f32), b: @Vector(2, f32)) f32 {
    return @reduce(.Add, a * b);
}

fn allOf(v: @Vector(4, bool)) bool {
    return @reduce(.And, v);
}

test "trivial_case_null" {
    const res = init(kernel_null);

    try std.testing.expectEqual(.outside, res.getSimpleCase().?);
    try std.testing.expect(!res.isInside(.{ 0, 0 }));
    try std.testing.expectEqual(.{ 0, 0 }, res.getGradient(.{ 0, 0 }));
    try std.testing.expectEqual(null, res.getNormal(.{ 0, 0 }));

    try std.testing.expectEqualDeep(
        Intersection{ .outside_trivial = {} },
        res.getIntersection(.{ 0, 0 }, .{ 1, 1 }),
    );
}

test "trivial_case_full" {
    const res = init(kernel_full);
    const pos = @Vector(2, f32){ 0.3, 0.4 };

    try std.testing.expectEqual(.inside, res.getSimpleCase().?);
    try std.testing.expect(res.isInside(.{ 0, 0 }));
    try std.testing.expectEqual(.{ 0, 0 }, res.getGradient(.{ 0, 0 }));
    try std.testing.expectEqual(null, res.getNormal(.{ 0, 0 }));

    try std.testing.expectEqualDeep(
        Intersection{ .inside_trivial = {} },
        res.getIntersection(pos, .{ 1, 1 }),
    );
}

const epsilon = 1e-5;

test "one_cell_ul_miss" {
    const res = init(.{ 1, 0, 0, 0 });
    const pos = @Vector(2, f32){ 0.9, 0.2 };
    const dir = @Vector(2, f32){ 0.3, -0.9 };

    try std.testing.expectEqual(null, res.getSimpleCase());
    try std.testing.expect(!res.isInside(pos));

    try std.testing.expectEqualDeep(
        Intersection{ .outside = {} },
        res.getIntersection(pos, dir),
    );

    const g = res.getGradient(pos);
    const n = res.getNormal(pos).?;

    try std.testing.expectApproxEqAbs(0.8, g[0], epsilon);
    try std.testing.expectApproxEqAbs(0.1, g[1], epsilon);
    try std.testing.expectApproxEqAbs(0.99228, n[0], epsilon);
    try std.testing.expectApproxEqAbs(0.12403, n[1], epsilon);
}

test "one_cell_ul_hits_in_bounds" {
    const res = init(.{ 1, 0, 0, 0 });
    const pos = @Vector(2, f32){ 0.7, 0.8 };
    const dir = @Vector(2, f32){ -0.3, -0.9 };

    try std.testing.expectEqual(null, res.getSimpleCase());
    try std.testing.expect(!res.isInside(pos));

    const result = res.getIntersection(pos, dir);
    try std.testing.expectApproxEqAbs(0.53017, result.hit[0], epsilon);
    try std.testing.expectApproxEqAbs(0.29052, result.hit[1], epsilon);

    const g = res.getGradient(result.hit);
    const n = res.getNormal(result.hit).?;

    try std.testing.expectApproxEqAbs(0.70948, g[0], epsilon);
    try std.testing.expectApproxEqAbs(0.46983, g[1], epsilon);
    try std.testing.expectApproxEqAbs(0.83376, n[0], epsilon);
    try std.testing.expectApproxEqAbs(0.55213, n[1], epsilon);
}
