const std = @import("std");
const builtin = @import("builtin");

const options = if (!builtin.is_test) @import("options") else struct {
    const profiling = false;
};

pub const ContextBase = struct {
    allocator: std.mem.Allocator,
    workerGroup: ThreadWorkerGroup,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const threads_available = try std.Thread.getCpuCount();

        return .{
            .allocator = allocator,
            .workerGroup = try ThreadWorkerGroup.init(allocator, threads_available - 1),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.workerGroup.deinit();
    }

    pub fn parent(self: *@This(), T: type) *T {
        return @alignCast(@fieldParentPtr("base", self));
    }
};

pub fn Context(comptime SystemsStruct: type) type {
    return struct {
        systems: SystemsStruct,
        base: ContextBase,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            var self = @This(){
                .systems = undefined,
                .base = try ContextBase.init(allocator),
            };

            inline for (comptime std.meta.fieldNames(SystemsStruct)) |field| {
                const system = &@field(self.systems, field);

                if (std.meta.hasFn(@TypeOf(system.*), "init")) {
                    system.* = try @TypeOf(system.*).init(self.base.allocator);
                } else {
                    system.* = .{};
                }
            }

            return self;
        }

        pub fn deinit(self: *@This()) void {
            inline for (comptime std.meta.fieldNames(SystemsStruct)) |field| {
                const system_ptr = &@field(self.systems, field);
                if (std.meta.hasMethod(@TypeOf(system_ptr), "deinit")) system_ptr.deinit();
            }

            self.base.deinit();
        }

        pub fn task(self: *@This(), comptime system_tag: anytype, comptime function_tag: anytype) PackagedTask {
            const field_name = @tagName(system_tag);

            if (!@hasField(SystemsStruct, field_name)) {
                @compileError("SystemsStruct does not have a field called: '" ++ field_name ++ "'");
            }

            return PackagedTask.init(&self.base, &@field(self.systems, field_name), function_tag);
        }
    };
}

fn WithNonComptimeFields(comptime Struct: type) type {
    const fields: []const std.builtin.Type.StructField = std.meta.fields(Struct);
    comptime var target_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, &target_fields) |f, *t| {
        t.* = f;
        t.is_comptime = false;
    }

    const structInfo = std.builtin.Type{
        .Struct = .{
            .is_tuple = false,
            .fields = &target_fields,
            .layout = .auto,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    };

    return @Type(structInfo);
}

pub fn context(allocator: std.mem.Allocator, system_tuple: anytype) !Context(WithNonComptimeFields(@TypeOf(system_tuple))) {
    var self = try Context(WithNonComptimeFields(@TypeOf(system_tuple))).init(allocator);
    self.systems = system_tuple;
    return self;
}

// const Id = enum(u32) {
//     invalid = std.math.maxInt(u32),
//     _,

//     pub fn toU32(self: @This()) u32 {
//         return @intFromEnum(self);
//     }

//     pub fn fromU32(v: u32) @This() {
//         return @enumFromInt(v);
//     }
// };

pub const SchedulePolicy = union(enum) {
    main_thread,
    thread_pool,
    // flush_then_main_thread,
    // flush_then_thread_pool,
    // fence_then_main_thread: Id,
    // fence_then_thread_pool: Id,
};

pub const PackagedTask = struct {
    self_ptr: *anyopaque,
    ctx_ptr: *ContextBase,
    function_ptr: *const fn (*anyopaque, *ContextBase) anyerror!void,
    name: if (options.profiling) [:0]const u8 else void,
    execution_time_ns: if (options.profiling) u64 else void,

    pub fn call(self: *@This()) !void {
        if (options.profiling) {
            var timer = try std.time.Timer.start();
            defer self.execution_time_ns = timer.read();
            return try self.function_ptr(self.self_ptr, self.ctx_ptr);
        } else {
            return try self.function_ptr(self.self_ptr, self.ctx_ptr);
        }
    }

    pub fn init(context_ptr: *ContextBase, struct_ptr: anytype, comptime function_tag: anytype) @This() {
        const function_name = @tagName(function_tag);

        switch (@typeInfo(@TypeOf(struct_ptr))) {
            .Pointer => {},
            else => @compileError("'struct_ptr' parameter must be a pointer to a single item"),
        }

        if (!std.meta.hasMethod(@TypeOf(struct_ptr), function_name)) {
            @compileError("Type '" ++ @typeName(@TypeOf(struct_ptr)) ++ "' does not have a method called: '" ++ function_name ++ "'");
        }

        const method = @field(@TypeOf(struct_ptr.*), function_name);

        const fn_typeinfo = switch (@typeInfo(@TypeOf(method))) {
            .Fn => |f| f,
            else => unreachable,
        };

        if (fn_typeinfo.params.len != 2 or
            fn_typeinfo.params[0].type != @TypeOf(struct_ptr) or
            fn_typeinfo.params[1].type != *ContextBase)
        {
            @compileError(
                "Function " ++ @typeName(@TypeOf(struct_ptr.*)) ++ "." ++ function_name ++
                    "(...) must have parameters " ++ "(" ++ @typeName(@TypeOf(struct_ptr)) ++
                    ", " ++ @typeName(*ContextBase) ++ ") and return anyerror!void",
            );
        }

        const Wrapper = struct {
            pub fn call(self: *anyopaque, ctx: *ContextBase) anyerror!void {
                return method(@alignCast(@ptrCast(self)), ctx);
            }
        };

        return .{
            .self_ptr = struct_ptr,
            .ctx_ptr = context_ptr,
            .function_ptr = Wrapper.call,
            .name = if (options.profiling) @typeName(@TypeOf(struct_ptr.*)) ++ "." ++ @tagName(function_tag) else {},
            .execution_time_ns = if (options.profiling) 0 else {},
        };
    }
};

// pub const Sequencer = struct {
//     callers: CallList,

//     pub const Unit = struct {
//         task: PackagedTask,
//         policy: SchedulePolicy,
//     };

//     pub const CallList = std.ArrayList(Unit);

//     pub fn init(allocator: std.mem.Allocator) @This() {
//         return .{ .callers = CallList.init(allocator) };
//     }

//     pub fn deinit(self: *@This()) void {
//         self.callers.deinit();
//     }

//     pub fn push(self: *@This(), task: PackagedTask, policy: SchedulePolicy) !void {
//         try self.callers.append(.{ .task = task, .policy = policy });
//     }

//     pub fn clear(self: *@This()) void {
//         self.callers.clearRetainingCapacity();
//     }

//     pub fn run(self: @This()) !void {
//         for (self.callers.items) |*item| try item.task.call();
//     }
// };

const ThreadWorker = struct {
    const Data = struct {
        allocator: std.mem.Allocator,
        queue_mtx: std.Thread.Mutex,
        queue_cnd: std.Thread.Condition,
        exiting: bool,
        queue: Queue,
        wait_mtx: std.Thread.Mutex,
        wait_cnd: std.Thread.Condition,
        unfinished_tasks: std.atomic.Value(usize),
        thread: std.Thread,
    };

    data: *Data,

    const Queue = std.fifo.LinearFifo(*PackagedTask, .{ .Static = queue_size_max });
    const queue_size_max = 16;

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var data = try allocator.create(Data);

        data.allocator = allocator;
        data.exiting = false;
        data.queue = Queue.init();
        data.queue_mtx = .{};
        data.queue_cnd = .{};
        data.unfinished_tasks.raw = 0;
        data.thread = try std.Thread.spawn(.{}, workerFunc, .{data});

        return .{ .data = data };
    }

    pub fn deinit(self: *@This()) void {
        self.data.exiting = true;
        self.data.queue_cnd.broadcast();
        self.data.thread.join();
        self.data.queue.deinit();
        self.data.allocator.destroy(self.data);
    }

    pub fn tryPush(self: *@This(), task: *PackagedTask) bool {
        _ = self.data.unfinished_tasks.fetchAdd(1, .SeqCst);

        self.data.queue_mtx.lock();
        defer self.data.queue_mtx.unlock();

        self.data.queue.writeItem(task) catch {
            _ = self.data.unfinished_tasks.fetchSub(1, .SeqCst);
            return false;
        };

        self.data.queue_cnd.broadcast();

        return true;
    }

    pub fn flush(self: *const @This()) void {
        self.data.wait_mtx.lock();
        defer self.data.wait_mtx.unlock();
        while (self.data.unfinished_tasks.load(.SeqCst) != 0) self.data.wait_cnd.wait(&self.data.wait_mtx);
    }

    pub fn workerFunc(data: *Data) !void {
        data.queue_mtx.lock();
        defer data.queue_mtx.unlock();

        while (true) {
            while (data.queue.readableLength() == 0) {
                if (data.exiting) return;
                data.queue_cnd.wait(&data.queue_mtx);
            }

            var task = data.queue.readItem() orelse unreachable;

            data.queue_mtx.unlock();
            defer data.queue_mtx.lock();

            try task.call();

            data.wait_mtx.lock();
            defer data.wait_mtx.unlock();

            _ = data.unfinished_tasks.fetchSub(1, .seq_cst);
            data.wait_cnd.broadcast();
        }
    }
};

test "ThreadWorker" {
    // var ctx = ContextBase.init(std.testing.allocator);

    // const SystemA = struct {
    //     number: i32 = 1,

    //     pub fn foo(self: *@This(), _: *ContextBase) void {
    //         self.number += 1;
    //     }
    // };

    // var sys = SystemA{};

    // var worker = try ThreadWorker.init(std.testing.allocator);
    // defer worker.deinit();

    // var caller_a = PackagedTask.init(&ctx, &sys, .foo);

    // try std.testing.expect(worker.tryPush(&caller_a));
    // try std.testing.expect(worker.tryPush(&caller_a));

    // worker.flush();

    // try std.testing.expectEqual(3, sys.number);
}

const ThreadWorkerGroup = struct {
    workers: std.ArrayList(ThreadWorker),
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !@This() {
        var workers = try std.ArrayList(ThreadWorker).initCapacity(allocator, thread_count);

        errdefer for (workers.items[0..]) |*worker| worker.deinit();
        for (0..thread_count) |_| workers.appendAssumeCapacity(try ThreadWorker.init(allocator));

        return .{ .workers = workers };
    }

    pub fn deinit(self: *@This()) void {
        for (self.workers.items[0..]) |*worker| worker.deinit();
        self.workers.deinit();
    }

    pub fn tryPush(self: *@This(), task: *PackagedTask, ms_timeout: usize) bool {
        const ns_timeout = ms_timeout * std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch @panic("Timer not available!");

        while (true) {
            for (0..self.workers.items.len) |_| {
                defer self.current_index += 1;
                if (self.current_index == self.workers.items.len) self.current_index = 0;
                if (self.workers.items[self.current_index].tryPush(task)) return true;
            }

            if (timer.read() > ns_timeout) return false;
        }
    }

    pub fn flush(self: *@This()) void {
        for (self.workers.items) |worker| worker.flush();
    }
};

test "ThreadWorkerGroup" {
    // var ctx = ContextBase.init(std.testing.allocator);

    // const SystemA = struct {
    //     number: std.atomic.Value(i32) = .{ .raw = 1 },

    //     pub fn foo(self: *@This(), _: *ContextBase) void {
    //         _ = self.number.fetchAdd(1, .Release);
    //     }
    // };

    // var sys = SystemA{};

    // var workerGroup = try ThreadWorkerGroup.init(std.testing.allocator, 1);
    // defer workerGroup.deinit();

    // var caller_a = PackagedTask.init(&ctx, &sys, .foo);

    // // Results are that generally starting a task takes 0.5us, so it is not worth it to offload tasks under 10us
    // // As opposed to synchronously called functions which are about 50x faster
    // for (0..999) |_| try std.testing.expect(workerGroup.tryPush(&caller_a, 1000));

    // workerGroup.flush();

    // if (options.profiling) std.debug.print("Caller A profiled {d:.3} us\n", .{caller_a.average_call_ns / std.time.ns_per_us});

    // try std.testing.expectEqual(1000, sys.number.load(.Acquire));
}

pub const Unit = struct {
    task: PackagedTask,
    policy: SchedulePolicy,

    pub fn init(context_ptr: *ContextBase, struct_ptr: anytype, comptime function_tag: anytype, policy: SchedulePolicy) @This() {
        return .{
            .task = PackagedTask.init(context_ptr, struct_ptr, function_tag),
            .policy = policy,
        };
    }

    pub fn run(self: @This()) !void {
        switch (self.policy) {
            .main_thread => try self.task.call(),
            .thread_pool => if (!self.task.ctx_ptr.workerGroup.tryPush(&self.task, 10 * 1000)) {
                if (options.profiling) {
                    std.log.err("Unit timed out pushing to worker group: {s}", .{self.task.name});
                }

                return error.WorkerGroupTimeout;
            },
        }
    }
};
