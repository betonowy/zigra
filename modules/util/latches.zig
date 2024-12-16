const std = @import("std");

pub const Latch = struct {
    mtx: std.Thread.Mutex = .{},
    cnd: std.Thread.Condition = .{},
    counter: usize,

    pub fn init(counter: usize) @This() {
        return .{ .counter = counter };
    }

    pub fn arrive(self: *@This()) void {
        self.mtx.lock();
        defer self.mtx.unlock();

        self.counter -= 1;
        while (self.counter > 0) self.cnd.wait(&self.mtx);
        self.cnd.broadcast();
    }
};

pub const SharedLatch = struct {
    ctx: *Ctx,

    const Ctx = struct {
        allocator: std.mem.Allocator,
        latch: Latch,
        references: std.atomic.Value(usize),
    };

    pub fn init(allocator: std.mem.Allocator, counter: usize) !@This() {
        const ctx = try allocator.create(Ctx);
        ctx.* = .{
            .allocator = allocator,
            .latch = .{ .counter = counter },
            .references = .{ .raw = counter },
        };
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: @This()) void {
        if (self.ctx.references.fetchSub(1, .acquire) == 1) self.ctx.allocator.destroy(self.ctx);
    }

    pub fn arrive(self: @This()) void {
        self.ctx.latch.arrive();
    }
};

test "Latch.One.Ok" {
    var latch = Latch.init(1);
    latch.arrive();
}

test "SharedLatch.One.Ok" {
    const latch = try SharedLatch.init(std.testing.allocator, 1);
    defer latch.deinit();
    latch.arrive();
}

test "Latch.Mt.Ok" {
    const thread_count = 4;
    var latch = Latch.init(thread_count + 1);

    const lambda = struct {
        pub fn work(p_latch: *Latch) void {
            p_latch.arrive();
        }
    };

    var threads = std.BoundedArray(std.Thread, thread_count){};
    defer for (threads.constSlice()) |t| t.join();

    for (0..thread_count) |_| threads.appendAssumeCapacity(
        try std.Thread.spawn(.{}, lambda.work, .{&latch}),
    );

    latch.arrive();
}

test "SharedLatch.Mt.Ok" {
    const thread_count = 4;
    const latch = try SharedLatch.init(std.testing.allocator, thread_count + 1);
    defer latch.deinit();

    const lambda = struct {
        pub fn work(p_latch: SharedLatch) void {
            p_latch.arrive();
            p_latch.deinit();
        }
    };

    var threads = std.BoundedArray(std.Thread, thread_count){};
    defer for (threads.constSlice()) |t| t.join();

    for (0..thread_count) |_| threads.appendAssumeCapacity(
        try std.Thread.spawn(.{}, lambda.work, .{latch}),
    );

    latch.arrive();
}
