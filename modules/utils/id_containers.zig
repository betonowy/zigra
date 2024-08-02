const std = @import("std");

pub fn IdArray(T: type) type {
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
                    "Shrinking IdArray active items capacity: len: {}, old cap: {}, new cap: {}",
                    .{ self.mal.len, self.mal.capacity, new_cap },
                );

                try self.mal.setCapacity(self.allocator, new_cap);
            }

            if (timer.read() > timeout_ns) return;

            if (self.free_list.capacity > self.free_list.len * 8 and self.free_list.items.len > 256) {
                const new_cap = self.mal.capacity / 4;

                std.log.info(
                    "Shrinking IdArray free items capacity: len: {}, old cap: {}, new cap: {}",
                    .{ self.free_list.len, self.free_list.capacity, new_cap },
                );

                try self.mal.setCapacity(self.allocator, self.mal.len * 2);
            }
        }
    };
}

test {
    var store = IdArray(usize).init(std.testing.allocator);
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

pub fn IdArray2(T: type) type {
    return struct {
        const Self = @This();
        const KeyMask = u64;
        const buffer_alignment = @max(@alignOf(T), @alignOf(KeyMask));

        allocator: std.mem.Allocator,
        buffer: []align(buffer_alignment) u8 = undefined,
        capacity: u32 = 0,

        pub const Iterator = struct {
            parent: *const Self,
            data: []T,
            keys: []KeyMask,
            cursor: u32 = 0,

            pub fn next(self: *@This()) ?*T {
                while (self.cursor < self.parent.capacity) {
                    defer self.cursor += 1;

                    const div = self.cursor / @bitSizeOf(KeyMask);
                    const mod = self.cursor % @bitSizeOf(KeyMask);

                    if ((self.keys[div] & (@as(KeyMask, 1) << @intCast(mod))) == 0) continue;

                    return &self.data[self.cursor];
                }

                return null;
            }

            pub fn reset(self: *@This()) void {
                self.cursor = 0;
            }
        };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: @This()) void {
            if (self.capacity == 0) return;
            self.allocator.free(self.buffer);
        }

        pub fn iterator(self: *const @This()) Iterator {
            return .{
                .parent = self,
                .data = self.getDataSlice(),
                .keys = self.getKeyMaskSlice(),
            };
        }

        pub fn add(self: *@This(), value: T) !u32 {
            if (self.findFreeId()) |id| {
                self.getDataSlice()[id] = value;
                self.setIdMask(id, true);
                return id;
            }

            try if (self.capacity == 0) self.setCapacityInit(@bitSizeOf(KeyMask)) else self.setCapacityMove(2 * self.capacity);

            const id = self.findFreeId() orelse unreachable;
            self.getDataSlice()[id] = value;
            self.setIdMask(id, true);
            return id;
        }

        pub fn at(self: *const @This(), id: u32) *T {
            return &self.getDataSlice()[id];
        }

        pub fn remove(self: *@This(), id: u32) void {
            self.setIdMask(id, false);
            self.getDataSlice()[id] = undefined;
        }

        fn findFreeId(self: @This()) ?u32 {
            for (self.getKeyMaskSlice(), 0..) |mask, i| {
                if (mask == std.math.boolMask(KeyMask, true)) continue;
                return @intCast(findFreeBitRange(mask, 0, @bitSizeOf(KeyMask)) + i * @bitSizeOf(KeyMask));
            }

            return null;
        }

        fn findFreeBitRange(value: KeyMask, comptime a: u32, comptime b: u32) u32 {
            if (b - a == 1) return a;

            std.debug.assert(value != std.math.boolMask(KeyMask, true));

            const bit_range = b - a;
            const half = a + @divExact(bit_range, 2);
            const mask = bitMask(KeyMask, a, half);

            if (mask & value != mask) return findFreeBitRange(value, a, half);

            return findFreeBitRange(value, half, b);
        }

        fn bitMask(MaskType: type, comptime a: u32, comptime b: u32) MaskType {
            var v: MaskType = 0;
            inline for (a..b) |i| v |= @as(@TypeOf(v), 1) << i;
            return v;
        }

        fn setCapacityInit(self: *@This(), size: u32) !void {
            std.debug.assert(self.capacity == 0);
            self.buffer = try self.allocator.alignedAlloc(u8, buffer_alignment, calculateRequiredBufferSize(size));
            self.capacity = size;
            @memset(self.getKeyMaskSlice(), 0);
        }

        fn setCapacityMove(self: @This(), size: u32) !void {
            _ = size; // autofix
            std.debug.assert(self.capacity != 0);
        }

        fn getKeyArraySize(capacity: u32) u32 {
            const div = capacity / @bitSizeOf(KeyMask);
            const mod = capacity % @bitSizeOf(KeyMask);
            return (div + @as(u32, if (mod == 0) 0 else 1));
        }

        fn getKeyArraySizeInBytes(capacity: u32) u32 {
            return getKeyArraySize(capacity) * @sizeOf(KeyMask);
        }

        fn getDataOffsetStart(capacity: u32) u32 {
            return std.mem.alignForward(u32, getKeyArraySizeInBytes(capacity), @alignOf(T));
        }

        fn calculateRequiredBufferSize(capacity: u32) u32 {
            return getDataOffsetStart(capacity) + capacity * @sizeOf(T);
        }

        pub fn getKeyMaskSlice(self: @This()) []KeyMask {
            const key_mask_start_ptr = @as([*]KeyMask, @ptrCast(self.buffer.ptr));
            return key_mask_start_ptr[0..@divExact(self.capacity, @bitSizeOf(KeyMask))];
        }

        pub fn getDataSlice(self: @This()) []T {
            const data_start_ptr = @as([*]T, @alignCast(@ptrCast(self.buffer.ptr + getDataOffsetStart(self.capacity))));
            return data_start_ptr[0..self.capacity];
        }

        fn setIdMask(self: *@This(), id: u32, comptime value: bool) void {
            const div = id / @bitSizeOf(KeyMask);
            const mod = id % @bitSizeOf(KeyMask);

            if (value) {
                self.getKeyMaskSlice()[div] |= @as(KeyMask, 1) << @intCast(mod);
            } else {
                self.getKeyMaskSlice()[div] &= ~(@as(KeyMask, 1) << @intCast(mod));
            }
        }
    };
}

test "IdArray2" {
    var ia = IdArray2(f32).init(std.testing.allocator);
    defer ia.deinit();

    try std.testing.expectEqual(0, (try ia.add(0)).id);
    try std.testing.expectEqual(1, (try ia.add(1)).id);
    try std.testing.expectEqual(2, (try ia.add(2)).id);
    try std.testing.expectEqual(3, (try ia.add(3)).id);
    try std.testing.expectEqual(4, (try ia.add(4)).id);

    ia.remove(0);

    try std.testing.expectEqual(0, (try ia.add(5)).id);
    try std.testing.expectEqual(5, (try ia.add(6)).id);

    ia.remove(3);

    try std.testing.expectEqual(3, (try ia.add(7)).id);

    var extractedValues = std.BoundedArray(f32, 128){};
    var it = ia.iterator();
    while (it.next()) |ptr| try extractedValues.append(ptr.*);

    try std.testing.expectEqualSlices(f32, &.{ 5, 1, 2, 7, 4, 6 }, extractedValues.constSlice());
}

pub fn ExtIdMappedIdArray2(T: type) type {
    return struct {
        arr: IdArray2(T),
        map: std.AutoHashMap(u32, u32),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .arr = IdArray2(T).init(allocator),
                .map = std.AutoHashMap(u32, u32).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.arr.deinit();
            self.map.deinit();
        }

        pub fn iterator(self: *const @This()) IdArray2(T).Iterator {
            return self.arr.iterator();
        }

        /// (Slow) get item pointer by it's external id
        pub fn getByExtId(self: *const @This(), ext_id: u32) ?*T {
            return if (self.map.get(ext_id)) |int_id| self.arr.at(int_id) else null;
        }

        /// (Fast) get item pointer by it's internal id
        pub fn getByIntId(self: *const @This(), int_id: u32) *T {
            return self.arr.at(int_id);
        }

        /// returns internal id for quicker lookup
        pub fn put(self: *@This(), ext_id: u32, v: T) !u32 {
            const int_id = try self.arr.add(v);
            try self.map.putNoClobber(ext_id, int_id);
            return int_id;
        }

        /// Asserts that the key is valid
        pub fn remove(self: *@This(), ext_id: u32) void {
            const kv = self.map.fetchRemove(ext_id) orelse unreachable;
            self.arr.remove(kv.value);
        }
    };
}

/// Strings used in this container must outlive the container
pub fn StaticStringMappedIdArray2(T: type) type {
    return struct {
        arr: IdArray2(T),
        map: std.StringHashMap(u32),
    };
}
