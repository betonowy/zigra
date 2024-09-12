const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");

pub const ContextBase = struct {
    allocator: std.mem.Allocator,
    thread_pool: *std.Thread.Pool = undefined,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const optimal_thread_count = try std.Thread.getCpuCount() - 1;

        var tp = try allocator.create(std.Thread.Pool);
        errdefer allocator.destroy(tp);

        try tp.init(.{ .allocator = allocator, .n_jobs = optimal_thread_count });

        var scratch_buf: [64]u8 = undefined;
        for (tp.threads, 0..) |thread, i| try thread.setName(try std.fmt.bufPrint(&scratch_buf, "thread_pool[{}]", .{i}));

        return .{
            .allocator = allocator,
            .thread_pool = tp,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
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
    };
}
