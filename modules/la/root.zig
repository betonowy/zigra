const std = @import("std");

pub const types = @import("types.zig");

pub usingnamespace types;

pub fn dot(a: anytype, b: anytype) types.VectorChild(@TypeOf(a, b)) {
    return @reduce(.Add, a * b);
}

test "dot_v2" {
    try std.testing.expectEqual(11, dot(types.V(2, f32){ 1, 2 }, types.V(2, f32){ 3, 4 }));
}

pub fn sqrLength(a: anytype) types.VectorChild(@TypeOf(a)) {
    return dot(a, a);
}

pub fn length(a: anytype) types.VectorChild(@TypeOf(a)) {
    return @sqrt(sqrLength(a));
}

test "len_v2" {
    try std.testing.expectEqual(5, length(types.V(2, f32){ 3, 4 }));
}

pub fn mix(a: anytype, b: anytype, c: anytype) @TypeOf(a, b) {
    comptime if (!types.isScalar(@TypeOf(c))) @compileError("Must be a scalar");
    comptime if (!types.isSupportedType(@TypeOf(a, b))) @compileError("Is not a supported type");

    return switch (@typeInfo(@TypeOf(a, b))) {
        .Array => mixMatrix(a, b, c),
        .Vector => mixVector(a, b, c),
        .Int, .Float, .ComptimeInt, .ComptimeFloat => mixScalar(a, b, c),
        else => unreachable,
    };
}

fn mixMatrix(a: anytype, b: anytype, c: anytype) @TypeOf(a, b) {
    var out: @TypeOf(a, b) = undefined;
    inline for (&a, &b, &out) |a_vec, b_vec, *out_vec| out_vec.* = mixVector(a_vec, b_vec, c);
    return out;
}

fn mixVector(a: anytype, b: anytype, c: anytype) @TypeOf(a, b) {
    return a * @as(@TypeOf(a), @splat(1 - c)) + b * @as(@TypeOf(b), @splat(c));
}

fn mixScalar(a: anytype, b: anytype, c: anytype) @TypeOf(a, b) {
    return a * (1 - c) + b * c;
}

test "mix" {
    try std.testing.expectEqual(
        types.M(2, 2, f32){
            .{ 2, 4 },
            .{ 3, 5 },
        },
        mix(
            types.M(2, 2, f32){
                .{ 1, 2 },
                .{ 2, 3 },
            },
            types.M(2, 2, f32){
                .{ 5, 10 },
                .{ 6, 11 },
            },
            0.25,
        ),
    );

    try std.testing.expectEqual(.{ 2, 4 }, mix(types.V(2, f32){ 1, 2 }, types.V(2, f32){ 5, 10 }, 0.25));
    try std.testing.expectEqual(2, mix(1, 5, 0.25));
}

pub fn fract(a: anytype) @TypeOf(a) {
    comptime if (!types.isSupportedType(@TypeOf(a))) @compileError("Is not a supported type");
    comptime if (!types.isFloat(@TypeOf(a)) and !types.isFloat(types.Child(@TypeOf(a)))) @compileError("Scalar type must be a float");

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

test "fract" {
    try std.testing.expectEqual(0.5, fract(-2.5));
    try std.testing.expectEqual(.{ 0.25, 0.5 }, fract(types.V(2, f64){ 2.25, 1.5 }));

    try std.testing.expectEqual(
        types.M(2, 2, f16){
            .{ 0.25, 0.5 },
            .{ 0.25, 0.5 },
        },
        fract(types.M(2, 2, f16){
            .{ 2.25, 1.5 },
            .{ 0.25, 0.5 },
        }),
    );
}

pub fn normalize(a: anytype) @TypeOf(a) {
    comptime if (!types.isVector(@TypeOf(a))) @compileError("Must be a vector");
    return a / @as(@TypeOf(a), @splat(length(a)));
}

test "normalize" {
    try std.testing.expectEqual(.{ 0.6, 0.8 }, normalize(types.V(2, f32){ 3, 4 }));
}

pub fn floatFromBool(T: type, b: anytype) types.Vec(types.len(@TypeOf(b)), T) {
    return @floatFromInt(@intFromBool(b));
}

fn rotate2d(v: @Vector(2, f32), angle: f32) @Vector(2, f32) {
    const cos = @cos(angle);
    const sin = @sin(angle);

    return .{
        v[0] * cos - v[1] * sin,
        v[0] * sin + v[1] * cos,
    };
}

fn clamp(v: anytype, a: anytype, b: anytype) @TypeOf(v, a, b) {
    return @min(b, @max(a, v));
}

fn cross(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{
        a[1] * b[2] - b[1] * a[2],
        a[2] * b[0] - b[2] * a[0],
        a[0] * b[1] - b[0] * a[1],
    };
}
