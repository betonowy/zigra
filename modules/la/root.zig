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

pub fn floatFromBool(T: type, b: anytype) types.V(types.len(@TypeOf(b)), T) {
    return @floatFromInt(@intFromBool(b));
}

test "floatFromBool" {
    try std.testing.expectEqual(.{ 1, 0 }, floatFromBool(f32, @Vector(2, bool){ true, false }));
}

pub fn rotate2d(v: @Vector(2, f32), angle: f32) @Vector(2, f32) {
    const cos = @cos(angle);
    const sin = @sin(angle);

    return .{
        v[0] * cos - v[1] * sin,
        v[0] * sin + v[1] * cos,
    };
}

test "rotate2d" {
    const res = rotate2d(.{ 1, 0 }, std.math.pi / 3.0);
    try std.testing.expectApproxEqAbs(0.500, res[0], 1e-3);
    try std.testing.expectApproxEqAbs(0.866, res[1], 1e-3);
}

pub fn perp2d(a: @Vector(2, f32)) @Vector(2, f32) {
    return .{ -a[1], a[0] };
}

test "perp2d" {
    try std.testing.expectEqual(.{ -2, 1 }, perp2d(.{ 1, 2 }));
}

pub fn clamp(v: anytype, a: anytype, b: anytype) @TypeOf(v, a, b) {
    return @min(b, @max(a, v));
}

test "clamp" {
    try std.testing.expectEqual(2, clamp(0, 2, 4));
    try std.testing.expectEqual(3, clamp(3, 2, 4));
    try std.testing.expectEqual(4, clamp(6, 2, 4));
}

pub fn cross(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{
        a[1] * b[2] - b[1] * a[2],
        a[2] * b[0] - b[2] * a[0],
        a[0] * b[1] - b[0] * a[1],
    };
}

test "cross" {
    try std.testing.expectEqual(.{ 3, -6, 3 }, cross(.{ 4, 5, 6 }, .{ 1, 2, 3 }));
}

pub fn splat(len: comptime_int, v: anytype) @Vector(len, @TypeOf(v)) {
    return @splat(v);
}

pub fn splatT(len: comptime_int, T: type, v: anytype) @Vector(len, T) {
    return @splat(v);
}

test "splat" {
    try std.testing.expectEqual(@Vector(2, f32){ 2, 2 }, splatT(2, f32, 2));
}

pub fn extend(len: comptime_int, v: anytype, tuple: anytype) @Vector(len, types.VectorChild(@TypeOf(v))) {
    var out: @Vector(len, types.VectorChild(@TypeOf(v))) = undefined;

    inline for (0..types.len(@TypeOf(v))) |i| out[i] = v[i];
    inline for (types.len(@TypeOf(v))..types.len(@TypeOf(out)), 0..) |i, j| out[i] = tuple[j];

    return out;
}

test "extend" {
    const v2 = @Vector(2, f32){ 1, 2 };
    const v4 = @Vector(4, f32){ 1, 2, 3, 4 };
    try std.testing.expectEqual(v4, extend(4, v2, .{ 3, 4 }));
}

pub fn zeroExtend(len: comptime_int, v: anytype) @Vector(len, types.VectorChild(@TypeOf(v))) {
    var out: @Vector(len, types.VectorChild(@TypeOf(v))) = undefined;
    inline for (0..types.len(@TypeOf(v))) |i| out[i] = v[i];
    inline for (types.len(@TypeOf(v))..types.len(@TypeOf(out))) |i| out[i] = 0;
    return out;
}

test "zeroExtend" {
    const v2 = @Vector(2, f32){ 1, 2 };
    const v4 = @Vector(4, f32){ 1, 2, 0, 0 };
    try std.testing.expectEqual(v4, zeroExtend(4, v2));
}

pub fn truncate(len: comptime_int, v: anytype) @Vector(len, types.VectorChild(@TypeOf(v))) {
    var out: @Vector(len, types.VectorChild(@TypeOf(v))) = undefined;
    inline for (0..len) |i| out[i] = v[i];
    return out;
}

test "truncate" {
    const v2 = @Vector(2, f32){ 1, 2 };
    const v4 = @Vector(4, f32){ 1, 2, 3, 4 };
    try std.testing.expectEqual(v2, truncate(2, v4));
}

pub fn normalizedRotation(rot: f32) f32 {
    return fract((rot + std.math.pi) / (std.math.pi * 2)) * 2 * std.math.pi - std.math.pi;
}

test "normalizedRotation" {
    try std.testing.expectApproxEqAbs(-std.math.pi, normalizedRotation(3 * std.math.pi), 1e-5);
    try std.testing.expectApproxEqAbs(1, normalizedRotation(2 * std.math.pi + 1), 1e-5);
    try std.testing.expectApproxEqAbs(-std.math.pi, normalizedRotation(std.math.pi), 1e-5);
    try std.testing.expectApproxEqAbs(1, normalizedRotation(1), 1e-5);
    try std.testing.expectApproxEqAbs(0, normalizedRotation(0), 1e-5);
    try std.testing.expectApproxEqAbs(-1, normalizedRotation(-1), 1e-5);
    try std.testing.expectApproxEqAbs(-std.math.pi, normalizedRotation(-std.math.pi), 1e-5);
    try std.testing.expectApproxEqAbs(-1, normalizedRotation(-2 * std.math.pi - 1), 1e-5);
    try std.testing.expectApproxEqAbs(-std.math.pi, normalizedRotation(-3 * std.math.pi), 1e-5);
}

pub fn srgbColor(T: type, r: T, g: T, b: T, a: T) @Vector(4, T) {
    return @floatCast(@Vector(4, f32){
        std.math.pow(f32, r, 2.2),
        std.math.pow(f32, g, 2.2),
        std.math.pow(f32, b, 2.2),
        std.math.pow(f32, a, 2.2),
    });
}
