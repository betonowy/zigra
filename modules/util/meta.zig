const std = @import("std");

pub fn logFn(log: anytype, src: std.builtin.SourceLocation) void {
    log.debug("{s}", .{src.fn_name});
}

pub fn UnwrapOptionals(comptime T: type) type {
    const type_info = @typeInfo(T);
    var struct_fields: [type_info.@"struct".fields.len]std.builtin.Type.StructField = undefined;

    for (type_info.@"struct".fields, &struct_fields) |src_field, *tmp_field| {
        tmp_field.* = src_field;

        switch (@typeInfo(tmp_field.type)) {
            else => {},
            .optional => |opt| {
                tmp_field.type = opt.child;
                tmp_field.default_value_ptr = null;
            },
        }
    }

    var new_info = @typeInfo(T);
    new_info.@"struct".fields = struct_fields[0..];
    new_info.@"struct".decls = &[0]std.builtin.Type.Declaration{};

    return @Type(new_info);
}

pub fn unwrapOptionals(value: anytype) UnwrapOptionals(@TypeOf(value)) {
    var complete_value: UnwrapOptionals(@TypeOf(value)) = undefined;

    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |field_name| {
        switch (@typeInfo(@TypeOf(@field(value, field_name)))) {
            .optional => @field(complete_value, field_name) = @field(value, field_name).?,
            else => @field(complete_value, field_name) = @field(value, field_name),
        }
    }

    return complete_value;
}

test "unwrapOptionals" {
    const Incomplete = struct {
        a: ?u32 = null,
        b: u32 = 0,
    };

    const incomplete = Incomplete{ .a = 1, .b = 2 };
    const complete = unwrapOptionals(incomplete);

    try std.testing.expectEqual(incomplete.a.?, complete.a);
    try std.testing.expectEqual(incomplete.b, complete.b);
}

pub fn asConstArray(ptr: anytype) *const [1]std.meta.Child(@TypeOf(ptr)) {
    return ptr;
}

pub fn asArray(ptr: anytype) *[1]std.meta.Child(@TypeOf(ptr)) {
    return ptr;
}

pub fn ReturnType(comptime Fn: anytype) type {
    return @typeInfo(@TypeOf(Fn)).@"fn".return_type.?;
}
