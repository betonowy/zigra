const std = @import("std");

pub const LoopAction = enum { repeat, advance };
pub const LifetimeState = enum { enter, enterLoop, normal, exitLoop, exit, dead };

pub fn OpaqueState(T: type) type {
    return struct {
        ptr: *anyopaque,
        vt: *const Vt,

        state: LifetimeState = .enter,

        const Vt = struct {
            name: [:0]const u8,
            long_name: [:0]const u8,
            enter_pfn: ?*const ActionFn = null,
            enterLoop_pfn: ?*const TransitionFn = null,
            updateEnter_pfn: ?*const ActionFn = null,
            tickEnter_pfn: ?*const ActionFn = null,
            tickExit_pfn: ?*const ActionFn = null,
            updateExit_pfn: ?*const ActionFn = null,
            exitLoop_pfn: ?*const TransitionFn = null,
            exit_pfn: ?*const InfallibleActionFn = null,
            deinit_pfn: *const DeinitFn,
        };

        const DeinitFn = fn (@This()) void;
        const ActionFn = fn (@This(), *Sequencer(T), *T) anyerror!void;
        const InfallibleActionFn = fn (@This(), *Sequencer(T), *T) void;
        const TransitionFn = fn (@This(), *Sequencer(T), *T) anyerror!LoopAction;

        pub fn enter(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
            if (self.vt.enter_pfn) |pfn| return pfn(self, state_stack, user_ctx);
        }

        pub fn enterLoop(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!LoopAction {
            return if (self.vt.enterLoop_pfn) |pfn| return pfn(self, state_stack, user_ctx) else return .advance;
        }

        pub fn updateEnter(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
            if (self.vt.updateEnter_pfn) |pfn| return pfn(self, state_stack, user_ctx);
        }

        pub fn tickEnter(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
            if (self.vt.tickEnter_pfn) |pfn| return pfn(self, state_stack, user_ctx);
        }

        pub fn tickExit(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
            if (self.vt.tickExit_pfn) |pfn| return pfn(self, state_stack, user_ctx);
        }

        pub fn updateExit(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
            if (self.vt.updateExit_pfn) |pfn| return pfn(self, state_stack, user_ctx);
        }

        pub fn exitLoop(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) anyerror!LoopAction {
            return if (self.vt.exitLoop_pfn) |pfn| pfn(self, state_stack, user_ctx) else return .advance;
        }

        pub fn exit(self: @This(), state_stack: *Sequencer(T), user_ctx: *T) void {
            if (self.vt.exit_pfn) |pfn| return pfn(self, state_stack, user_ctx);
        }

        pub fn deinit(self: @This()) void {
            self.vt.deinit_pfn(self);
        }

        pub fn initFrom(pimpl: anytype) @This() {
            return .{
                .vt = ptrToVtable(@TypeOf(pimpl)),
                .ptr = pimpl,
            };
        }

        pub fn ptrToVtable(Impl: type) *const Vt {
            const Self = @This();

            const lambda = struct {
                pub fn enter(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).enter(state_stack, user_ctx);
                }

                pub fn enterLoop(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!LoopAction {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).enterLoop(state_stack, user_ctx);
                }

                pub fn updateEnter(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).updateEnter(state_stack, user_ctx);
                }

                pub fn tickEnter(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).tickEnter(state_stack, user_ctx);
                }

                pub fn tickExit(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).tickExit(state_stack, user_ctx);
                }

                pub fn updateExit(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).updateExit(state_stack, user_ctx);
                }

                pub fn exitLoop(self: Self, state_stack: *Sequencer(T), user_ctx: *T) anyerror!LoopAction {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).exitLoop(state_stack, user_ctx);
                }

                pub fn exit(self: Self, state_stack: *Sequencer(T), user_ctx: *T) void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).exit(state_stack, user_ctx);
                }

                pub fn deinit(self: Self) void {
                    return @as(Impl, @ptrCast(@alignCast(self.ptr))).deinit();
                }

                fn nameSuffix(name: [:0]const u8) [:0]const u8 {
                    const last_dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
                    return name[last_dot + 1 ..];
                }
            };

            const long_name = @typeName(std.meta.Child(Impl));
            const short_name = comptime lambda.nameSuffix(long_name);

            return &.{
                .enter_pfn = if (std.meta.hasMethod(Impl, "enter")) &lambda.enter else null,
                .enterLoop_pfn = if (std.meta.hasMethod(Impl, "enterLoop")) &lambda.enterLoop else null,
                .updateEnter_pfn = if (std.meta.hasMethod(Impl, "updateEnter")) &lambda.updateEnter else null,
                .tickEnter_pfn = if (std.meta.hasMethod(Impl, "tickEnter")) &lambda.tickEnter else null,
                .tickExit_pfn = if (std.meta.hasMethod(Impl, "tickExit")) &lambda.tickExit else null,
                .updateExit_pfn = if (std.meta.hasMethod(Impl, "updateExit")) &lambda.updateExit else null,
                .exitLoop_pfn = if (std.meta.hasMethod(Impl, "exitLoop")) &lambda.exitLoop else null,
                .exit_pfn = if (std.meta.hasMethod(Impl, "exit")) &lambda.exit else null,
                .deinit_pfn = &lambda.deinit,
                .long_name = long_name,
                .name = short_name,
            };
        }
    };
}

pub fn Sequencer(T: type) type {
    return struct {
        arena_next: std.heap.ArenaAllocator,

        current: std.ArrayList(OpaqueState(T)),
        next: ?[]OpaqueState(T) = null,
        drop_level: ?usize = null,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .current = std.ArrayList(OpaqueState(T)).init(allocator),
                .arena_next = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn safeDeinit(self: *@This(), user_ctx: *T) void {
            var reverse_current = std.mem.reverseIterator(self.current.items);
            while (reverse_current.nextPtr()) |o| switch (o.state) {
                .enter => {
                    o.deinit();
                    o.state = .dead;
                },
                .enterLoop, .normal, .exitLoop, .exit => {
                    o.exit(self, user_ctx);
                    o.deinit();
                    o.state = .dead;
                },
                .dead => {},
            };

            self.deinit();
        }

        pub fn deinit(self: @This()) void {
            self.arena_next.deinit();
            self.current.deinit();
        }

        pub fn set(self: *@This(), new: []const OpaqueState(T)) !void {
            self.next = try self.arena_next.allocator().dupe(OpaqueState(T), new);
        }

        pub fn setAny(self: *@This(), new: anytype) !void {
            const fields: []const std.builtin.Type.StructField = switch (@typeInfo(@TypeOf(new))) {
                .@"struct" => std.meta.fields(@TypeOf(new)),
                else => @compileError("'new' must be a struct or tuple"),
            };

            var opaque_new: [fields.len]OpaqueState(T) = undefined;

            inline for (fields, &opaque_new) |field, *out| switch (@typeInfo(field.type)) {
                .pointer => |p| {
                    if (p.is_const) @compileError("pointer must be non-const");
                    switch (p.size) {
                        .one => out.* = OpaqueState(T).initFrom(@field(new, field.name)),
                        else => @compileError("pointer must be a pointer to a single item"),
                    }
                },
                else => @compileError("field must be a pointer to a single item"),
            };

            try self.set(&opaque_new);
        }

        pub const UpdateResult = enum { stable, transition };

        pub fn update(self: *@This(), user_ctx: *T, ticks: usize) !UpdateResult {
            switch (try self.handleStateChange(user_ctx)) {
                .transition => return .transition,
                .stable => {
                    const slice = self.current.items;

                    try self.updateUp(slice, user_ctx, .updateEnter);

                    for (0..ticks) |_| {
                        try self.updateUp(slice, user_ctx, .tickEnter);
                        try self.updateDown(slice, user_ctx, .tickExit);
                    }

                    try self.updateDown(slice, user_ctx, .updateExit);

                    return .stable;
                },
            }
        }

        inline fn updateUp(self: *@This(), slice: []const OpaqueState(T), user_ctx: *T, comptime fn_name: anytype) !void {
            for (slice) |state| try self.updateCall(state, user_ctx, fn_name);
        }

        inline fn updateDown(self: *@This(), slice: []const OpaqueState(T), user_ctx: *T, comptime fn_name: anytype) !void {
            var reverse_iterator = std.mem.reverseIterator(slice);
            while (reverse_iterator.next()) |state| try self.updateCall(state, user_ctx, fn_name);
        }

        inline fn updateCall(self: *@This(), state: OpaqueState(T), user_ctx: *T, comptime fn_name: anytype) !void {
            try @call(.always_inline, @field(OpaqueState(T), @tagName(fn_name)), .{ state, self, user_ctx });
        }

        fn handleStateChange(self: *@This(), user_ctx: *T) !UpdateResult {
            const next = self.next orelse &.{};
            // try to initialize uninitialized states upwards before anything else happens
            // even if this isn't our target state stack, elements might not be in a normal state for previous target yet
            for (self.current.items) |*o| switch (o.state) {
                .enter => {
                    try o.enter(self, user_ctx);
                    o.state = .enterLoop;
                    return .transition;
                },
                .enterLoop => switch (try o.enterLoop(self, user_ctx)) {
                    .repeat => {
                        return .transition;
                    },
                    .advance => {
                        o.state = .normal;
                    },
                },
                .normal => {},
                else => std.debug.assert(!std.mem.eql(u8, std.mem.sliceAsBytes(self.current.items), std.mem.sliceAsBytes(next))),
            };

            const drop_level = blk: {
                // if this is our target state, we're stable
                if (std.mem.eql(u8, std.mem.sliceAsBytes(self.current.items), std.mem.sliceAsBytes(next))) return .stable;

                // if this is not our target state, determine how many states we need to drop
                const min_len = @min(self.current.items.len, next.len);
                for (self.current.items[0..min_len], next[0..min_len], 0..) |a, b, i| if (a.ptr != b.ptr) break :blk i;
                break :blk min_len;
            };

            // downgrade initialized states that must be gone
            {
                var reverse_current = std.mem.reverseIterator(self.current.items[drop_level..]);
                while (reverse_current.nextPtr()) |o| switch (o.state) {
                    .enter => {
                        o.deinit();
                        o.state = .dead;
                    },
                    .enterLoop, .normal => {
                        o.state = .exitLoop;
                        return .transition;
                    },
                    .exitLoop => switch (try o.exitLoop(self, user_ctx)) {
                        .repeat => {
                            return .transition;
                        },
                        .advance => {
                            o.state = .exit;
                            return .transition;
                        },
                    },
                    .exit => {
                        o.exit(self, user_ctx);
                        o.deinit();
                        o.state = .dead;
                    },
                    .dead => {},
                };
            }

            try self.current.resize(drop_level);
            try self.current.appendSlice(next[drop_level..]);
            self.next = self.current.items;
            _ = self.arena_next.reset(.retain_capacity);

            return .transition;
        }
    };
}

test OpaqueState {
    const UserCtx = struct {};
    const UserSequencer = Sequencer(UserCtx);

    const S = struct {
        value: usize = 0,

        pub fn enter(self: *@This(), _: *UserSequencer, _: *UserCtx) void {
            self.value += 1;
        }

        pub fn enterLoop(self: *@This(), _: *UserSequencer, _: *UserCtx) LoopAction {
            self.value += 2;
            return .advance;
        }

        pub fn updateEnter(self: *@This(), _: *UserSequencer, _: *UserCtx) void {
            self.value += 4;
        }

        pub fn tickEnter(self: *@This(), _: *UserSequencer, _: *UserCtx) void {
            self.value += 8;
        }

        pub fn tickExit(self: *@This(), _: *UserSequencer, _: *UserCtx) void {
            self.value += 16;
        }

        pub fn updateExit(self: *@This(), _: *UserSequencer, _: *UserCtx) void {
            self.value += 32;
        }

        pub fn exitLoop(self: *@This(), _: *UserSequencer, _: *UserCtx) LoopAction {
            self.value += 64;
            return .advance;
        }

        pub fn exit(self: *@This(), _: *UserSequencer, _: *UserCtx) void {
            self.value += 128;
        }

        pub fn deinit(_: *@This()) void {}
    };

    var s = S{};
    const o = OpaqueState(UserCtx).initFrom(&s);

    try o.enter(undefined, undefined);
    try std.testing.expectEqual(.advance, o.enterLoop(undefined, undefined));
    try o.updateEnter(undefined, undefined);
    try o.tickEnter(undefined, undefined);
    try o.tickExit(undefined, undefined);
    try o.updateExit(undefined, undefined);
    try std.testing.expectEqual(.advance, o.exitLoop(undefined, undefined));
    o.exit(undefined, undefined);
    o.deinit();

    try std.testing.expectEqual(1 + 2 + 4 + 8 + 16 + 32 + 64 + 128, s.value);
    try std.testing.expectEqualStrings("stack_states.decltest.OpaqueState.S", o.vt.long_name);
    try std.testing.expectEqualStrings("S", o.vt.name);
}

test Sequencer {
    const UserCtx = std.ArrayList(u8);
    const UserSequencer = Sequencer(UserCtx);

    const S = struct {
        symbol: u8,

        n_enter_loop: usize = 0,
        n_exit_loop: usize = 0,
        n_loop_limit: usize = 2,

        saved_ctx: *UserCtx = undefined,

        pub fn enter(self: *@This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
            self.saved_ctx = ctx;
        }

        pub fn enterLoop(self: *@This(), _: *UserSequencer, ctx: *UserCtx) LoopAction {
            self.write(ctx.writer(), @src());
            self.n_enter_loop += 1;
            if (self.n_enter_loop >= self.n_loop_limit) {
                self.n_enter_loop = 0;
                return .advance;
            } else return .repeat;
        }

        pub fn updateEnter(self: *@This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
        }

        pub fn tickEnter(self: *@This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
        }

        pub fn tickExit(self: *@This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
        }

        pub fn updateExit(self: *@This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
        }

        pub fn exitLoop(self: *@This(), _: *UserSequencer, ctx: *UserCtx) LoopAction {
            self.write(ctx.writer(), @src());
            self.n_exit_loop += 1;
            if (self.n_exit_loop >= self.n_loop_limit) {
                self.n_exit_loop = 0;
                return .advance;
            } else return .repeat;
        }

        pub fn exit(self: *@This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
        }

        pub fn deinit(self: @This()) void {
            self.write(self.saved_ctx.writer(), @src());
        }

        fn write(self: @This(), writer: UserCtx.Writer, src: std.builtin.SourceLocation) void {
            writer.print("{c}:{s}\n", .{ self.symbol, src.fn_name }) catch unreachable;
        }
    };

    var recorder = std.ArrayList(u8).init(std.testing.allocator);
    defer recorder.deinit();

    var a = S{ .symbol = 'a' };
    var b = S{ .symbol = 'b' };
    var c = S{ .symbol = 'c' };

    var stack_sequencer = UserSequencer.init(std.testing.allocator);
    defer stack_sequencer.deinit();

    try std.testing.expectEqual(.stable, stack_sequencer.update(&recorder, 1));

    try stack_sequencer.setAny(.{ &a, &b, &c });

    for (0..7) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
    try std.testing.expectEqual(.stable, stack_sequencer.update(&recorder, 2));

    try stack_sequencer.setAny(.{ &a, &c });

    for (0..9) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
    try std.testing.expectEqual(.stable, stack_sequencer.update(&recorder, 1));

    try stack_sequencer.setAny(.{});

    for (0..7) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
    try std.testing.expectEqual(.stable, stack_sequencer.update(&recorder, 1));

    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\a:enterLoop
        \\b:enter
        \\b:enterLoop
        \\b:enterLoop
        \\c:enter
        \\c:enterLoop
        \\c:enterLoop
        \\a:updateEnter
        \\b:updateEnter
        \\c:updateEnter
        \\a:tickEnter
        \\b:tickEnter
        \\c:tickEnter
        \\c:tickExit
        \\b:tickExit
        \\a:tickExit
        \\a:tickEnter
        \\b:tickEnter
        \\c:tickEnter
        \\c:tickExit
        \\b:tickExit
        \\a:tickExit
        \\c:updateExit
        \\b:updateExit
        \\a:updateExit
        \\c:exitLoop
        \\c:exitLoop
        \\c:exit
        \\c:deinit
        \\b:exitLoop
        \\b:exitLoop
        \\b:exit
        \\b:deinit
        \\c:enter
        \\c:enterLoop
        \\c:enterLoop
        \\a:updateEnter
        \\c:updateEnter
        \\a:tickEnter
        \\c:tickEnter
        \\c:tickExit
        \\a:tickExit
        \\c:updateExit
        \\a:updateExit
        \\c:exitLoop
        \\c:exitLoop
        \\c:exit
        \\c:deinit
        \\a:exitLoop
        \\a:exitLoop
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
}

test "Sequencer.EdgeCases" {
    const UserCtx = std.ArrayList(u8);
    const UserSequencer = Sequencer(UserCtx);

    const S = struct {
        symbol: u8,
        next_failure_point: LifetimeState = .dead,
        saved_ctx: *UserCtx = undefined,

        pub fn enter(self: *@This(), _: *UserSequencer, ctx: *UserCtx) !void {
            self.write(ctx.writer(), @src());
            if (self.next_failure_point == .enter) return error.UserFailure;
        }

        pub fn enterLoop(self: @This(), _: *UserSequencer, ctx: *UserCtx) !LoopAction {
            self.write(ctx.writer(), @src());
            return if (self.next_failure_point == .enterLoop) return error.UserFailure else .advance;
        }

        pub fn updateEnter(self: @This(), _: *UserSequencer, ctx: *UserCtx) !void {
            self.write(ctx.writer(), @src());
            if (self.next_failure_point == .normal) return error.UserFailure;
        }

        pub fn tickEnter(self: @This(), _: *UserSequencer, ctx: *UserCtx) !void {
            self.write(ctx.writer(), @src());
        }

        pub fn tickExit(self: @This(), _: *UserSequencer, ctx: *UserCtx) !void {
            self.write(ctx.writer(), @src());
        }

        pub fn updateExit(self: @This(), _: *UserSequencer, ctx: *UserCtx) !void {
            self.write(ctx.writer(), @src());
        }

        pub fn exitLoop(self: @This(), _: *UserSequencer, ctx: *UserCtx) !LoopAction {
            self.write(ctx.writer(), @src());
            return if (self.next_failure_point == .exitLoop) error.UserFailure else .advance;
        }

        pub fn exit(self: @This(), _: *UserSequencer, ctx: *UserCtx) void {
            self.write(ctx.writer(), @src());
        }

        pub fn deinit(self: @This()) void {
            self.write(self.saved_ctx.writer(), @src());
        }

        fn write(self: @This(), writer: UserCtx.Writer, src: std.builtin.SourceLocation) void {
            writer.print("{c}:{s}\n", .{ self.symbol, src.fn_name }) catch unreachable;
        }
    };

    var recorder = std.ArrayList(u8).init(std.testing.allocator);
    defer recorder.deinit();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder, .next_failure_point = .enter };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\b:deinit
        \\a:deinit
        \\
    , recorder.items);
    recorder.clearRetainingCapacity();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder, .next_failure_point = .enterLoop };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        for (0..2) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\b:deinit
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
    recorder.clearRetainingCapacity();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder, .next_failure_point = .enter };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        for (0..2) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\b:enter
        \\b:deinit
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
    recorder.clearRetainingCapacity();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder, .next_failure_point = .enterLoop };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        for (0..3) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\b:enter
        \\b:enterLoop
        \\b:exit
        \\b:deinit
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
    recorder.clearRetainingCapacity();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder, .next_failure_point = .normal };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        for (0..3) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\b:enter
        \\b:enterLoop
        \\a:updateEnter
        \\b:exit
        \\b:deinit
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
    recorder.clearRetainingCapacity();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder, .next_failure_point = .exitLoop };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        for (0..3) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectEqual(.stable, stack_sequencer.update(&recorder, 1));
        try stack_sequencer.setAny(.{});
        try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\b:enter
        \\b:enterLoop
        \\a:updateEnter
        \\b:updateEnter
        \\a:tickEnter
        \\b:tickEnter
        \\b:tickExit
        \\a:tickExit
        \\b:updateExit
        \\a:updateExit
        \\b:exitLoop
        \\b:exit
        \\b:deinit
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
    recorder.clearRetainingCapacity();
    {
        var a = S{ .symbol = 'a', .saved_ctx = &recorder, .next_failure_point = .exitLoop };
        var b = S{ .symbol = 'b', .saved_ctx = &recorder };

        var stack_sequencer = UserSequencer.init(std.testing.allocator);
        defer stack_sequencer.safeDeinit(&recorder);

        try stack_sequencer.setAny(.{ &a, &b });
        for (0..3) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectEqual(.stable, stack_sequencer.update(&recorder, 1));
        try stack_sequencer.setAny(.{});
        for (0..3) |_| try std.testing.expectEqual(.transition, stack_sequencer.update(&recorder, 1));
        try std.testing.expectError(error.UserFailure, stack_sequencer.update(&recorder, 1));
    }
    try std.testing.expectEqualStrings(
        \\a:enter
        \\a:enterLoop
        \\b:enter
        \\b:enterLoop
        \\a:updateEnter
        \\b:updateEnter
        \\a:tickEnter
        \\b:tickEnter
        \\b:tickExit
        \\a:tickExit
        \\b:updateExit
        \\a:updateExit
        \\b:exitLoop
        \\b:exit
        \\b:deinit
        \\a:exitLoop
        \\a:exit
        \\a:deinit
        \\
    , recorder.items);
}
