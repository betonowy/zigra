const std = @import("std");

pub fn IdStore(T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mal: std.MultiArrayList(Container) = .{},
        free_list: std.ArrayListUnmanaged(u32) = .{},

        const Self = @This();
        const ArrayType = std.MultiArrayList(Container);

        const Container = struct {
            active: bool,
            payload: T,
        };

        const Iterator = struct {
            self: *Self,
            slice: ArrayType.Slice,
            id: u32,

            const Fields = struct {
                active: *bool,
                payload: *T,
            };

            pub fn next(self: *@This()) ?Fields {
                while (self.id < self.slice.len) {
                    defer self.id += 1;

                    const active_field = &self.slice.items(.active)[self.id];

                    if (active_field.*) return .{
                        .active = active_field,
                        .payload = &self.slice.items(.payload)[self.id],
                    };
                }

                return null;
            }

            pub fn destroyCurrent(self: *@This()) !void {
                std.debug.assert(self.mal.items(.active)[self.id]);

                if (self.id == self.slice.len - 1) {
                    _ = self.self.mal.pop();
                    self.slice.len -= 1;
                    return;
                }

                self.slice.items(.active)[self.id] = false;
                self.slice.items(.payload)[self.id] = undefined;
                try self.self.free_list.append(self.self.allocator, self.id);
            }
        };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *@This()) void {
            self.mal.deinit(self.allocator);
            self.free_list.deinit(self.allocator);
        }

        pub fn createId(self: *@This()) !u32 {
            if (self.free_list.popOrNull()) |id| {
                self.mal.items(.active)[id] = true;
                return id;
            }

            try self.mal.append(self.allocator, .{ .active = true, .payload = undefined });
            return @intCast(self.mal.len - 1);
        }

        pub fn push(self: *@This(), value: T) !u32 {
            const id = try self.createId();
            self.mal.items(.payload)[id] = value;
            return id;
        }

        pub fn destroyId(self: *@This(), id: u32) !void {
            std.debug.assert(self.mal.items(.active)[id]);

            if (id == self.mal.len - 1) {
                _ = self.mal.pop();
                return;
            }

            const s = self.slice();
            s.items(.active)[id] = false;
            s.items(.payload)[id] = undefined;
            try self.free_list.append(self.allocator, id);
        }

        pub fn slice(self: *@This()) ArrayType.Slice {
            return self.mal.slice();
        }

        pub fn iterator(self: *@This()) Iterator {
            return .{ .self = self, .slice = self.mal.slice(), .id = 0 };
        }

        pub fn tidy(self: *@This(), timeout_ns: u64) !void {
            const timer = try std.time.Timer.start();

            if (self.mal.capacity > self.mal.len * 8 and self.mal.capacity > 256) {
                const new_cap = self.mal.capacity / 4;

                std.log.info(
                    "Shrinking IdStore active items capacity: len: {}, old cap: {}, new cap: {}",
                    .{ self.mal.len, self.mal.capacity, new_cap },
                );

                try self.mal.setCapacity(self.allocator, new_cap);
            }

            if (timer.read() > timeout_ns) return;

            if (self.free_list.capacity > self.free_list.len * 8 and self.free_list.items.len > 256) {
                const new_cap = self.mal.capacity / 4;

                std.log.info(
                    "Shrinking IdStore free items capacity: len: {}, old cap: {}, new cap: {}",
                    .{ self.free_list.len, self.free_list.capacity, new_cap },
                );

                try self.mal.setCapacity(self.allocator, self.mal.len * 2);
            }
        }
    };
}

test {
    var store = IdStore(usize).init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(0, try store.createId());
    try std.testing.expectEqual(1, try store.createId());
    try std.testing.expectEqual(2, try store.createId());
    try std.testing.expectEqual(0, store.free_list.items.len);
    try store.destroyId(1);
    try std.testing.expectEqual(1, store.free_list.items.len);
    try store.destroyId(2);
    try std.testing.expectEqual(1, store.free_list.items.len);
    try std.testing.expectEqual(1, try store.createId());
    try std.testing.expectEqual(0, store.free_list.items.len);
    try std.testing.expectEqual(2, try store.createId());

    var iterator = store.iterator();

    while (iterator.next()) |fields| {
        std.debug.assert(fields.active.*);
    }
}
