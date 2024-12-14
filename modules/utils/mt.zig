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

// pub fn LockFreeMpMcQueue(T: type) type {
//     return struct {
//         const AtomicSize = std.atomic.Value(usize);

//         items: []T,
//         head_acq: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
//         head_rel: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
//         tail_acq: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },
//         tail_rel: AtomicSize align(std.atomic.cache_line) = .{ .raw = 0 },

//         pub fn init(allocator: std.mem.Allocator, len: usize) !@This() {
//             return .{ .items = try allocator.alloc(T, len) };
//         }

//         pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
//             allocator.free(self.items);
//         }

//         pub fn push(self: *@This(), value: T) !void {
//             var head_curr = self.head_acq.load(.unordered);
//             var head_next = (head_curr + 1) % self.items.len;
//             var tail = self.tail_rel.load(.acquire);
//             if (head_next == tail) return error.Overflow;

//             while (self.head_acq.cmpxchgWeak(head_curr, head_next, .acquire, .monotonic)) |new_head_curr| {
//                 head_curr = new_head_curr;
//                 head_next = (head_curr + 1) % self.items.len;
//                 tail = self.tail_rel.load(.acquire);
//                 if (head_next == tail) return error.Overflow;
//             }

//             self.items[head_curr] = value;

//             while (self.head_rel.cmpxchgWeak(head_curr, head_next, .release, .monotonic) != null) {}
//         }

//         pub fn pop(self: *@This()) ?T {
//             var tail_curr = self.tail_acq.load(.unordered);
//             var tail_next = (tail_curr + 1) % self.items.len;
//             var head = self.head_rel.load(.acquire);
//             if (tail_curr == head) return null;

//             while (self.tail_acq.cmpxchgWeak(tail_curr, tail_next, .acquire, .monotonic)) |new_tail_curr| {
//                 tail_curr = new_tail_curr;
//                 tail_next = (tail_curr + 1) % self.items.len;
//                 head = self.head_rel.load(.acquire);
//                 if (tail_curr == head) return null;
//             }

//             const value = self.items[tail_curr];

//             while (self.tail_rel.cmpxchgWeak(tail_curr, tail_next, .release, .monotonic) != null) {}

//             return value;
//         }
//     };
// }

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

// test "MpMcQueue_mt_2" {
//     var timer = try std.time.Timer.start();
//     defer std.debug.print("MpMc_mt_2: {} us\n", .{timer.read() / std.time.ns_per_us});

//     const Queue = LockFreeMpMcQueue(usize);
//     var queue = try Queue.init(std.testing.allocator, 8);
//     defer queue.deinit(std.testing.allocator);

//     var sum: usize = 0;

//     const workers = struct {
//         pub fn producer(queue_ptr: *Queue) void {
//             for (0..iteration_count) |i| {
//                 while (queue_ptr.push(i) == error.Overflow) {}
//             }
//         }

//         pub fn consumer(queue_ptr: *Queue, sum_ptr: *usize) void {
//             var counter: usize = 0;
//             while (counter < iteration_count) {
//                 if (queue_ptr.pop()) |value| {
//                     sum_ptr.* += value;
//                     counter += 1;
//                 }
//             }
//         }
//     };

//     const p = try std.Thread.spawn(.{}, workers.producer, .{&queue});
//     const c = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });

//     p.join();
//     c.join();

//     try std.testing.expectEqual(iteration_sum, sum);
// }

// test "LockFreeMpMcQueue_mt_4" {
//     var timer = try std.time.Timer.start();
//     defer std.debug.print("MpMc_mt_4: {} us\n", .{timer.read() / std.time.ns_per_us});

//     const Queue = LockFreeMpMcQueue(usize);
//     var queue = try Queue.init(std.testing.allocator, 8);
//     defer queue.deinit(std.testing.allocator);

//     const AtomicSize = std.atomic.Value(usize);

//     var sum = AtomicSize.init(0);
//     var counter = AtomicSize.init(0);

//     const workers = struct {
//         pub fn producer(queue_ptr: *Queue, counter_ptr: *AtomicSize) void {
//             while (true) {
//                 const value = counter_ptr.fetchAdd(1, .monotonic);
//                 if (value >= iteration_count) break;
//                 while (true) {
//                     queue_ptr.push(value) catch continue;
//                     break;
//                 }
//             }
//         }

//         pub fn consumer(queue_ptr: *Queue, sum_ptr: *AtomicSize) void {
//             while (true) {
//                 var expected_sum = sum_ptr.load(.unordered);
//                 if (queue_ptr.pop()) |value| {
//                     while (sum_ptr.cmpxchgWeak(
//                         expected_sum,
//                         expected_sum + value,
//                         .monotonic,
//                         .monotonic,
//                     )) |new| expected_sum = new;
//                 }
//                 if (expected_sum == iteration_sum) break;
//             }
//         }
//     };

//     const p1 = try std.Thread.spawn(.{}, workers.producer, .{ &queue, &counter });
//     const p2 = try std.Thread.spawn(.{}, workers.producer, .{ &queue, &counter });
//     const c1 = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });
//     const c2 = try std.Thread.spawn(.{}, workers.consumer, .{ &queue, &sum });

//     p1.join();
//     p2.join();
//     c1.join();
//     c2.join();

//     try std.testing.expectEqual(iteration_sum, sum.raw);
// }

pub fn ThreadLoopCore(Payload: type) type {
    return struct {
        allocator: std.mem.Allocator,
        memory_pool: MemoryPool,

        pending_tasks: usize = 0,
        list: ExecutableList = .{},

        mtx: std.Thread.Mutex = .{},
        cv_produced: std.Thread.Condition = .{},
        cv_consumed: std.Thread.Condition = .{},

        workers: []std.Thread,
        shutting_down: bool = false,

        const Fn = fn (*@This(), Payload) void;
        const Executable = struct { func: *const Fn, payload: Payload };
        const ExecutableList = std.DoublyLinkedList(Executable);
        const MemoryPool = std.heap.MemoryPoolExtra(ExecutableList.Node, .{});

        pub fn init(allocator: std.mem.Allocator, n_workers: usize) !*@This() {
            const self = try allocator.create(@This());
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .memory_pool = MemoryPool.init(allocator),
                .workers = undefined,
            };

            var workers_arr = try std.ArrayList(std.Thread).initCapacity(allocator, n_workers);
            errdefer {
                self.mtx.lock();
                self.shutting_down = true;
                self.cv_produced.broadcast();
                self.mtx.unlock();

                for (workers_arr.items) |worker| worker.join();
                workers_arr.deinit();
            }

            for (0..n_workers) |_| workers_arr.appendAssumeCapacity(
                try std.Thread.spawn(.{ .allocator = allocator }, workerLoop, .{self}),
            );

            self.workers = workers_arr.toOwnedSlice() catch unreachable;

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.mtx.lock();
            self.shutting_down = true;
            self.cv_produced.broadcast();
            self.mtx.unlock();

            for (self.workers) |worker| worker.join();

            self.memory_pool.deinit();
            self.allocator.free(self.workers);
            self.allocator.destroy(self);
        }

        pub fn enqueue(self: *@This(), func: *const Fn, payload: Payload) !void {
            self.mtx.lock();
            defer self.mtx.unlock();

            const node = try self.memory_pool.create();
            node.* = .{ .data = .{ .func = func, .payload = payload } };
            self.list.append(node);
            self.pending_tasks += 1;
            self.cv_produced.signal();
        }

        pub fn tryExecuteOne(self: *@This()) bool {
            self.mtx.lock();
            defer self.mtx.unlock();
            return self.internalTryExecuteOne();
        }

        pub fn flush(self: *@This()) void {
            self.mtx.lock();
            while (self.pending_tasks != 0) self.cv_consumed.wait(&self.mtx);
            self.mtx.unlock();
        }

        fn workerLoop(self: *@This()) void {
            self.mtx.lock();
            defer self.mtx.unlock();

            while (!self.shutting_down) if (!self.internalTryExecuteOne()) {
                self.cv_produced.wait(&self.mtx);
            };
        }

        fn internalTryExecuteOne(self: *@This()) bool {
            const node = self.list.popFirst() orelse return false;

            self.mtx.unlock();
            node.data.func(self, node.data.payload);
            self.mtx.lock();

            self.pending_tasks -= 1;
            self.cv_consumed.broadcast();
            self.memory_pool.destroy(node);

            return true;
        }
    };
}

test "ThreadLoopCore" {
    const TestThreadLoop = ThreadLoopCore(*std.atomic.Value(usize));

    const local = struct {
        pub fn exec(_: *TestThreadLoop, counter: *std.atomic.Value(usize)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    const iterations = 100;

    var tp = try TestThreadLoop.init(std.testing.allocator, 4);
    defer tp.deinit();

    var counter = std.atomic.Value(usize).init(0);
    for (0..iterations) |_| try tp.enqueue(local.exec, &counter);

    tp.flush();
    try std.testing.expectEqual(iterations, counter.load(.unordered));
}

const ThreadLoopExecutor = struct {
    tp: *ThreadPoolImpl,

    const ThreadPoolImpl = ThreadLoopCore(Payload);

    const Payload = struct {};

    pub fn init(allocator: std.mem.Allocator, n_workers: usize) !void {
        return .{ .tp = try ThreadPoolImpl.init(allocator, n_workers) };
    }

    pub fn deinit(self: @This()) void {
        self.deinit();
    }

    pub fn tryExecuteOne(self: @This()) void {
        self.tryExecuteOne();
    }

    pub fn flush(self: @This()) void {
        self.flush();
    }

    // pub fn enqueue(self: @This()) !void {
    //     self.enqueue();
    // }
};
