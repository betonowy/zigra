const std = @import("std");

pub fn SpScQueue(T: type) type {
    return struct {
        const AtomicSize = std.atomic.Value(usize);

        items: []T,
        head: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
        tail: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },

        pub fn init(allocator: std.mem.Allocator, len: usize) !@This() {
            return .{ .items = try allocator.alloc(T, len) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        pub fn push(self: *@This(), value: T) !void {
            const head_curr = self.head.load(.unordered);
            const head_next = (head_curr + 1) % self.items.len;
            const tail = self.tail.load(.acquire);

            if (head_next == tail) return error.Overflow;

            self.items[head_curr] = value;
            self.head.store(head_next, .release);
        }

        pub fn pop(self: *@This()) ?T {
            const tail_curr = self.tail.load(.unordered);
            const tail_next = (tail_curr + 1) % self.items.len;
            const head = self.head.load(.acquire);

            if (tail_curr == head) return null;

            defer self.tail.store(tail_next, .release);
            return self.items[tail_curr];
        }
    };
}

pub fn MpMcQueue(T: type) type {
    return struct {
        const AtomicSize = std.atomic.Value(usize);

        queue: SpScQueue(T),
        lock_p: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
        lock_c: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },

        pub fn init(allocator: std.mem.Allocator, len: usize) !@This() {
            return .{ .queue = try SpScQueue(T).init(allocator, len) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.queue.deinit(allocator);
        }

        pub fn push(self: *@This(), value: T) !void {
            while (self.lock_p.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {}
            defer self.lock_p.store(0, .release);
            return self.queue.push(value);
        }

        pub fn pop(self: *@This()) ?T {
            while (self.lock_c.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {}
            defer self.lock_c.store(0, .release);
            return self.queue.pop();
        }
    };
}

pub fn LockFreeMpMcQueue(T: type) type {
    return struct {
        const AtomicSize = std.atomic.Value(usize);

        items: []T,
        head_acq: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
        head_rel: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
        tail_acq: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
        tail_rel: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },

        pub fn init(allocator: std.mem.Allocator, len: usize) !@This() {
            return .{ .items = try allocator.alloc(T, len) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        pub fn push(self: *@This(), value: T) !void {
            var head_curr = self.head_acq.load(.unordered);
            var head_next = (head_curr + 1) % self.items.len;
            var tail = self.tail_rel.load(.acquire);
            if (head_next == tail) return error.Overflow;

            while (self.head_acq.cmpxchgWeak(head_curr, head_next, .acquire, .monotonic)) |new_head_curr| {
                head_curr = new_head_curr;
                head_next = (head_curr + 1) % self.items.len;
                tail = self.tail_rel.load(.acquire);
                if (head_next == tail) return error.Overflow;
            }

            self.items[head_curr] = value;

            while (self.head_rel.cmpxchgWeak(head_curr, head_next, .release, .monotonic) != null) {}
        }

        pub fn pop(self: *@This()) ?T {
            var tail_curr = self.tail_acq.load(.unordered);
            var tail_next = (tail_curr + 1) % self.items.len;
            var head = self.head_rel.load(.acquire);
            if (tail_curr == head) return null;

            while (self.tail_acq.cmpxchgWeak(tail_curr, tail_next, .acquire, .monotonic)) |new_tail_curr| {
                tail_curr = new_tail_curr;
                tail_next = (tail_curr + 1) % self.items.len;
                head = self.head_rel.load(.acquire);
                if (tail_curr == head) return null;
            }

            defer while (self.tail_rel.cmpxchgWeak(tail_curr, tail_next, .release, .monotonic) != null) {};

            return self.items[tail_curr];
        }
    };
}

const iteration_count = 16384;
const iteration_sum = 134209536;

test "SpScQueue_st" {
    var timer = try std.time.Timer.start();
    defer std.debug.print("SpSc_st: {} us\n", .{timer.read() / std.time.ns_per_us});

    const Queue = SpScQueue(usize);
    var queue = try Queue.init(std.testing.allocator, 9);
    defer queue.deinit(std.testing.allocator);

    var sum: usize = 0;

    for (0..7) |i| try queue.push(i);
    for (0..7) |_| sum += queue.pop().?;

    for (7..14) |i| try queue.push(i);
    for (7..14) |_| sum += queue.pop().?;

    for (14..iteration_count) |i| {
        try queue.push(i);
        sum += queue.pop().?;
    }

    try std.testing.expectEqual(iteration_sum, sum);
}

test "SpScQueue_mt" {
    var timer = try std.time.Timer.start();
    defer std.debug.print("SpSc_mt: {} us\n", .{timer.read() / std.time.ns_per_us});

    const Queue = SpScQueue(usize);
    var queue = try Queue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);

    var sum: usize = 0;

    const workers = struct {
        pub fn producer(queue_ptr: *Queue) void {
            for (0..iteration_count) |i| {
                while (queue_ptr.push(i) == error.Overflow) {}
            }
        }

        pub fn consumer(queue_ptr: *Queue, sum_ptr: *usize) void {
            var counter: usize = 0;
            while (counter < iteration_count) {
                if (queue_ptr.pop()) |value| {
                    sum_ptr.* += value;
                    counter += 1;
                }
            }
        }
    };

    const p = try std.Thread.spawn(.{}, workers.producer, .{&queue});
    const c = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });

    p.join();
    c.join();

    try std.testing.expectEqual(iteration_sum, sum);
}

test "MpMcQueue_mt_2" {
    var timer = try std.time.Timer.start();
    defer std.debug.print("MpMc_mt_2: {} us\n", .{timer.read() / std.time.ns_per_us});

    const Queue = LockFreeMpMcQueue(usize);
    var queue = try Queue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);

    var sum: usize = 0;

    const workers = struct {
        pub fn producer(queue_ptr: *Queue) void {
            for (0..iteration_count) |i| {
                while (queue_ptr.push(i) == error.Overflow) {}
            }
        }

        pub fn consumer(queue_ptr: *Queue, sum_ptr: *usize) void {
            var counter: usize = 0;
            while (counter < iteration_count) {
                if (queue_ptr.pop()) |value| {
                    sum_ptr.* += value;
                    counter += 1;
                }
            }
        }
    };

    const p = try std.Thread.spawn(.{}, workers.producer, .{&queue});
    const c = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });

    p.join();
    c.join();

    try std.testing.expectEqual(iteration_sum, sum);
}

test "LockFreeMpMcQueue_mt_4" {
    var timer = try std.time.Timer.start();
    defer std.debug.print("MpMc_mt_4: {} us\n", .{timer.read() / std.time.ns_per_us});

    const Queue = LockFreeMpMcQueue(usize);
    var queue = try Queue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);

    const AtomicSize = std.atomic.Value(usize);

    var sum = AtomicSize.init(0);
    var counter = AtomicSize.init(0);

    const workers = struct {
        pub fn producer(queue_ptr: *Queue, counter_ptr: *AtomicSize) void {
            while (true) {
                const value = counter_ptr.fetchAdd(1, .monotonic);
                if (value >= iteration_count) break;
                while (true) {
                    queue_ptr.push(value) catch continue;
                    break;
                }
            }
        }

        pub fn consumer(queue_ptr: *Queue, sum_ptr: *AtomicSize) void {
            while (true) {
                var expected_sum = sum_ptr.load(.unordered);
                if (queue_ptr.pop()) |value| {
                    while (sum_ptr.cmpxchgWeak(
                        expected_sum,
                        expected_sum + value,
                        .monotonic,
                        .monotonic,
                    )) |new| expected_sum = new;
                }
                if (expected_sum == iteration_sum) break;
            }
        }
    };

    const p1 = try std.Thread.spawn(.{}, workers.producer, .{ &queue, &counter });
    const p2 = try std.Thread.spawn(.{}, workers.producer, .{ &queue, &counter });
    const c1 = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });
    const c2 = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });

    p1.join();
    p2.join();
    c1.join();
    c2.join();

    try std.testing.expectEqual(iteration_sum, sum.raw);
}
