const std = @import("std");

const Node = struct {
    next: ?*@This() = null,
    prev: ?*@This() = null,

    pub fn link(self: *@This(), other: *@This()) void {
        self.prev = other;
        self.next = other.next;
        if (other.next) |next| next.prev = self;
        other.next = self;
    }

    pub fn unlink(self: *@This()) void {
        if (self.prev) |prev| prev.next = self.next;
        if (self.next) |next| next.prev = self.prev;
    }
};

pub fn LinkedChild(FnType: type) type {
    return struct {
        node: Node = .{},
        cb: *const FnType,

        pub fn link(self: *@This(), other: *LinkedParent(FnType)) void {
            self.node.link(&other.node);
        }

        pub fn unlink(self: *@This()) void {
            self.node.unlink();
        }
    };
}

pub fn LinkedParent(FnType: type) type {
    const Child = LinkedChild(FnType);

    const ReturnType = comptime switch (@typeInfo(@typeInfo(FnType).@"fn".return_type.?)) {
        .error_union => anyerror!void,
        .void => void,
        else => unreachable,
    };

    return struct {
        node: Node = .{},

        pub fn callAll(self: *@This(), args: anytype) ReturnType {
            var current = self.node.next;

            while (current) |c| : (current = c.next) {
                const child: *Child = @fieldParentPtr("node", c);

                var cb_args: std.meta.ArgsTuple(FnType) = undefined;

                if (@TypeOf(cb_args[0]) == *anyopaque) {
                    const field_count = std.meta.fields(@TypeOf(args)).len;

                    cb_args[0] = child;
                    inline for (0..field_count) |i| cb_args[i + 1] = args[i];

                    switch (@typeInfo(@typeInfo(FnType).@"fn".return_type.?)) {
                        .error_union => try @call(.auto, child.cb, cb_args),
                        .void => @call(.auto, child.cb, cb_args),
                        else => unreachable,
                    }
                } else {
                    switch (@typeInfo(@typeInfo(FnType).@"fn".return_type.?)) {
                        .error_union => try @call(.auto, child.cb, args),
                        .void => @call(.auto, child.cb, args),
                        else => unreachable,
                    }
                }
            }
        }
    };
}

test "Linked" {
    const ctx = struct {
        var sum: i32 = 0;

        pub fn foo(x: i32) !void {
            sum += x;
        }
    };

    const CbType = fn (i32) anyerror!void;
    const Parent = LinkedParent(CbType);
    const Child = LinkedChild(CbType);

    var p = Parent{};
    var c = Child{ .cb = &ctx.foo };

    c.node.link(&p.node);
    try p.callAll(.{1});

    try std.testing.expectEqual(1, ctx.sum);

    c.node.unlink();
    try p.callAll(.{1});

    try std.testing.expectEqual(1, ctx.sum);
}
