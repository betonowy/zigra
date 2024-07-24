const std = @import("std");

pub fn V(x: comptime_int, T: type) type {
    return @Vector(x, T);
}

pub fn M(x: comptime_int, y: comptime_int, T: type) type {
    return [x]@Vector(y, T);
}

pub fn isVector(T: type) bool {
    return switch (@typeInfo(T)) {
        .Vector => true,
        else => false,
    };
}

test "isVector" {
    try comptime std.testing.expect(isVector(V(2, i32)));
    try comptime std.testing.expect(!isVector([2]f32));
}

pub fn isMatrix(T: type) bool {
    return switch (@typeInfo(T)) {
        .Array => |Array| if (Array.sentinel == null) isVector(Array.child) else false,
        else => false,
    };
}

test "isMatrix" {
    try comptime std.testing.expect(isMatrix(M(2, 3, i32)));
    try comptime std.testing.expect(!isMatrix([2:V(3, f32){ 1, 2, 3 }]V(3, f32)));
}

pub fn isScalar(T: type) bool {
    return switch (@typeInfo(T)) {
        .Int, .Float, .ComptimeInt, .ComptimeFloat => true,
        else => false,
    };
}

test "isScalar" {
    try comptime std.testing.expect(isScalar(i32));
    try comptime std.testing.expect(isScalar(f16));
    try comptime std.testing.expect(!isScalar(V(2, u32)));
}

pub fn isFloat(T: type) bool {
    return switch (@typeInfo(T)) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
}

test "isFloat" {
    try comptime std.testing.expect(isFloat(f32));
    try comptime std.testing.expect(!isFloat(i32));
}

pub fn isSupportedType(T: type) bool {
    return isScalar(T) or isVector(T) or isMatrix(T);
}

pub fn Child(T: type) type {
    if (!isVector(T) and !isMatrix(T)) @compileError("Must be a vector or a matrix");

    return switch (@typeInfo(T)) {
        .Vector => |Vector| Vector.child,
        .Array => |Array| std.meta.Child(Array.child),
        else => unreachable,
    };
}

pub fn VectorChild(T: type) type {
    return if (!isVector(T)) @compileError("Must be a vector") else Child(T);
}

pub fn MatrixChild(T: type) type {
    return if (!isMatrix(T)) @compileError("Must be a matrix") else Child(T);
}

test "Child" {
    try comptime std.testing.expectEqual(f32, Child(V(2, f32)));
    try comptime std.testing.expectEqual(i16, Child(M(2, 4, i16)));
}

pub fn len(T: type) comptime_int {
    if (!isVector(T)) @compileError("Must be a vector");
    return @typeInfo(T).Vector.len;
}

test "length" {
    try comptime std.testing.expectEqual(4, len(V(4, u8)));
}

pub fn dim(T: type) [2]comptime_int {
    if (!isMatrix(T)) @compileError("Must be a matrix");
    const Array = @typeInfo(T).Array;
    const Vector = @typeInfo(Array.child).Vector;
    return .{ Array.len, Vector.len };
}

test "dim" {
    try comptime std.testing.expectEqual([_]comptime_int{ 4, 3 }, dim(M(4, 3, u8)));
}
