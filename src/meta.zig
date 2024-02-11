const std = @import("std");

pub fn UnwrapOptionals(comptime T: type) type {
    const type_info = @typeInfo(T);
    var struct_fields: [type_info.Struct.fields.len]std.builtin.Type.StructField = undefined;

    for (type_info.Struct.fields, &struct_fields) |src_field, *tmp_field| {
        tmp_field.* = src_field;

        switch (@typeInfo(tmp_field.type)) {
            else => {},
            .Optional => |opt| {
                tmp_field.type = opt.child;
                tmp_field.default_value = null;
            },
        }
    }

    var new_info = @typeInfo(T);
    new_info.Struct.fields = struct_fields[0..];
    new_info.Struct.decls = &[0]std.builtin.Type.Declaration{};

    return @Type(new_info);
}

pub fn unwrapOptionals(value: anytype) UnwrapOptionals(@TypeOf(value)) {
    var complete_value: UnwrapOptionals(@TypeOf(value)) = undefined;

    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |field_name| {
        switch (@typeInfo(@TypeOf(@field(value, field_name)))) {
            .Optional => @field(complete_value, field_name) = @field(value, field_name).?,
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
