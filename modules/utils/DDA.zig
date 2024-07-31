const std = @import("std");
const builtin = @import("builtin");

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

    pub fn fract(a: anytype) @TypeOf(a) {
        return switch (@typeInfo(@TypeOf(a))) {
            else => unreachable,
            .Array,
            => fractMatrix(a),
            .Vector,
            .Float,
            .ComptimeFloat,
            => fractVectorOrScalar(a),
        };
    }

    fn fractMatrix(a: anytype) @TypeOf(a) {
        var out: @TypeOf(a) = undefined;
        inline for (&a, &out) |a_vec, *out_vec| out_vec.* = fractVectorOrScalar(a_vec);
        return out;
    }

    fn fractVectorOrScalar(a: anytype) @TypeOf(a) {
        return a - @floor(a);
    }
};

dir: @Vector(2, f32),
target_cell: @Vector(2, i32),
current_cell: @Vector(2, i32),
step: @Vector(2, i32),
delta: @Vector(2, f32),
side: @Vector(2, f32),
iterations: u32 = 0,
hit_side: bool = false,
finished: bool,

const zero_2i: @Vector(2, i32) = @splat(0);
const one_2i: @Vector(2, i32) = @splat(1);
const one_2f: @Vector(2, f32) = @splat(1);
const two_2i: @Vector(2, i32) = @splat(2);

pub fn init(start: @Vector(2, f32), target: @Vector(2, f32)) @This() {
    std.debug.assert(@reduce(.Or, start != target));

    const dir = la.normalize(target - start);
    const delta = @abs(one_2f / dir);

    const cond_i: @Vector(2, i32) = @intFromBool(target > start);
    const cond_f: @Vector(2, f32) = @floatFromInt(cond_i);
    const cond_f_neg = one_2f - cond_f;

    const fract_pos = la.fract(start);
    const fract_inv = la.fract(one_2f - start);

    return @This(){
        .dir = dir,
        .target_cell = @intFromFloat(@floor(target)),
        .current_cell = @intFromFloat(@floor(start)),
        .step = cond_i * two_2i - one_2i,
        .delta = delta,
        .side = (cond_f * fract_inv + cond_f_neg * fract_pos) * delta,
        .finished = @reduce(.And, start == target),
    };
}

pub fn next(self: *@This()) void {
    self.iterations += 1;
    self.hit_side = self.side[0] >= self.side[1];

    const ratio_i: @Vector(2, i32) = if (self.hit_side) .{ 0, 1 } else .{ 1, 0 };
    const ratio_f: @Vector(2, f32) = @floatFromInt(ratio_i);

    self.current_cell += self.step * ratio_i;
    self.side += self.delta * ratio_f;

    self.finished = !@reduce(.And, self.step * (self.target_cell - self.current_cell) >= zero_2i);
}

pub fn dist(self: *const @This()) f32 {
    return switch (self.hit_side) {
        true => self.side[1] - self.delta[1],
        false => self.side[0] - self.delta[0],
    };
}

test "simple_shape" {
    const expected_cells = [_]@Vector(2, i32){
        undefined, .{ 0, 1 }, .{ 1, 1 }, .{ 2, 1 },
        .{ 2, 2 }, .{ 3, 2 }, .{ 3, 3 }, .{ 4, 3 },
    };

    const expected_dists = [_]f32{
        undefined, 0,   0,       1.25,
        1.66667,   2.5, 3.33333, 3.75,
    };

    var dda = init(.{ 0, 0 }, .{ 4, 3 });
    try std.testing.expectEqual(.{ 0.8, 0.6 }, dda.dir);

    dda.next();

    while (!dda.finished) : (dda.next()) {
        try std.testing.expectEqual(expected_cells[dda.iterations], dda.current_cell);
        try std.testing.expectApproxEqRel(expected_dists[dda.iterations], dda.dist(), 1e-5);

        std.debug.print("cell: {}, fpos: {d:.2}\n", .{ dda.current_cell, @floor(@Vector(2, f32){ 0, 0 } + @as(@Vector(2, f32), @splat(dda.dist())) * dda.dir) });
    }

    try std.testing.expectEqual(8, dda.iterations);
}

test "dda_regression_01" {
    var dda = init(.{ 5.39839782e+01, -4.56062431e+01 }, .{ 5.58791198e+01, -4.78331947e+01 });

    dda.next();

    while (!dda.finished) : (dda.next()) {
        std.debug.print("cell: {}, fpos: {d:.2}\n", .{ dda.current_cell, @floor(@Vector(2, f32){ 5.39839782e+01, -4.56062431e+01 } + @as(@Vector(2, f32), @splat(dda.dist())) * dda.dir) });
    }
}
