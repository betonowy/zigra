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

const iteration_count = 16384;
const iteration_sum = 134209536;

test "SpScQueue_st" {
    // var timer = try std.time.Timer.start();
    // defer std.debug.print("SpSc_st: {} us\n", .{timer.read() / std.time.ns_per_us});

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
