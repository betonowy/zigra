const std = @import("std");

pub fn IdArray(T: type) type {
    return struct {
        const Self = @This();
        const KeyMask = u64;
        const buffer_alignment = @max(@alignOf(T), @alignOf(KeyMask));

        allocator: std.mem.Allocator,
        buffer: []align(buffer_alignment) u8 = undefined,

        data: []T = undefined,
        keys: []KeyMask = undefined,

        capacity: u32 = 0,
        last_insert_index: u32 = 0,

        pub const Iterator = struct {
            parent: *const Self,
            cursor: u32 = 0,
            bound: u32 = 0,

            pub fn next(self: *@This()) ?*T {
                while (self.cursor < self.bound) {
                    defer self.cursor += 1;

                    const div = self.cursor / @bitSizeOf(KeyMask);
                    const mod = self.cursor % @bitSizeOf(KeyMask);

                    if ((self.parent.keys[div] & (@as(KeyMask, 1) << @intCast(mod))) == 0) continue;

                    return &self.parent.data[self.cursor];
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
            return .{ .parent = self, .bound = self.capacity };
        }

        pub fn boundedIterator(self: *const @This(), a: u32, b: u32) Iterator {
            return .{ .parent = self, .cursor = a, .bound = b };
        }

        pub fn put(self: *@This(), value: T) !u32 {
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
            self.data[id] = undefined;
        }

        pub fn shrinkIfOversized(self: *@This(), ratio: u32) !bool {
            std.debug.assert(ratio > 1);

            if (self.capacity == 0) return false;
            var target_size: u32 = 0;

            for (1..self.keys.len + 1) |i| {
                const index = self.keys.len - i;
                if (self.keys[index] != 0) {
                    target_size = @intCast((index + 1) * @bitSizeOf(KeyMask));
                    break;
                }
            }

            if (target_size == 0) {
                self.allocator.free(self.buffer);
                self.last_insert_index = 0;
                self.capacity = 0;
                return false;
            }

            if (self.keys.len * @bitSizeOf(KeyMask) / target_size < ratio) return false;

            const old = self.*;
            defer self.allocator.free(old.buffer);

            self.buffer = try self.allocator.alignedAlloc(u8, buffer_alignment, calculateRequiredBufferSize(target_size));
            self.capacity = target_size;
            self.updateSlices();

            @memcpy(self.data, old.data[0..self.data.len]);
            @memcpy(self.keys, old.keys[0..self.keys.len]);
            return true;
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
            self.updateSlices();

            @memset(self.keys, 0);
        }

        fn setCapacityMove(self: *@This(), size: u32) !void {
            std.debug.assert(self.capacity != 0);

            const old = self.*;
            defer self.allocator.free(old.buffer);

            self.buffer = try self.allocator.alignedAlloc(u8, buffer_alignment, calculateRequiredBufferSize(size));
            self.capacity = size;
            self.updateSlices();

            @memcpy(self.data[0..old.data.len], old.data);
            @memcpy(self.keys[0..old.keys.len], old.keys);
            @memset(self.keys[old.keys.len..], 0);
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

        fn updateSlices(self: *@This()) void {
            self.data = self.getDataSlice();
            self.keys = self.getKeyMaskSlice();
        }

        fn getKeyMaskSlice(self: @This()) []KeyMask {
            const key_mask_start_ptr = @as([*]KeyMask, @ptrCast(self.buffer.ptr));
            return key_mask_start_ptr[0..@divExact(self.capacity, @bitSizeOf(KeyMask))];
        }

        fn getDataSlice(self: @This()) []T {
            const data_start_ptr = @as([*]T, @alignCast(@ptrCast(self.buffer.ptr + getDataOffsetStart(self.capacity))));
            return data_start_ptr[0..self.capacity];
        }

        fn setIdMask(self: *@This(), id: u32, comptime value: bool) void {
            const div = id / @bitSizeOf(KeyMask);
            const mod = id % @bitSizeOf(KeyMask);

            if (value) {
                self.keys[div] |= @as(KeyMask, 1) << @intCast(mod);
            } else {
                self.keys[div] &= ~(@as(KeyMask, 1) << @intCast(mod));
            }
        }
    };
}

test "IdArray_BasicLifetime" {
    var ia = IdArray(f32).init(std.testing.allocator);
    defer ia.deinit();

    try std.testing.expectEqual(0, try ia.put(0));
    try std.testing.expectEqual(1, try ia.put(1));
    try std.testing.expectEqual(2, try ia.put(2));
    try std.testing.expectEqual(3, try ia.put(3));
    try std.testing.expectEqual(4, try ia.put(4));

    ia.remove(0);

    try std.testing.expectEqual(0, try ia.put(5));
    try std.testing.expectEqual(5, try ia.put(6));

    ia.remove(3);

    try std.testing.expectEqual(3, try ia.put(7));

    var extractedValues = std.BoundedArray(f32, 6){};
    var it = ia.iterator();
    while (it.next()) |ptr| try extractedValues.append(ptr.*);

    try std.testing.expectEqualSlices(f32, &.{ 5, 1, 2, 7, 4, 6 }, extractedValues.constSlice());
}

test "IdArray_GrowAndShrink" {
    var ia = IdArray(usize).init(std.testing.allocator);
    defer ia.deinit();

    const size = 128;
    const shrink_size = 64;

    for (0..size) |i| try std.testing.expectEqual(i, try ia.put(i));
    for (0..size) |i| try std.testing.expectEqual(i, ia.at(@intCast(i)).*);

    try std.testing.expectEqual(size, ia.data.len);
    try std.testing.expectEqual(@divExact(size, @bitSizeOf(@TypeOf(ia).KeyMask)), ia.keys.len);

    for (0..size) |i| ia.remove(@intCast(i));

    try std.testing.expectEqual(size, ia.capacity);
    try std.testing.expect(try ia.shrinkIfOversized(2));
    try std.testing.expectEqual(0, ia.capacity);

    for (0..size) |i| try std.testing.expectEqual(i, try ia.put(i + 10000));
    for (0..size) |i| try std.testing.expectEqual(i + 10000, ia.at(@intCast(i)).*);
    for (shrink_size..size) |i| ia.remove(@intCast(i));

    try std.testing.expectEqual(size, ia.capacity);
    try std.testing.expect(try ia.shrinkIfOversized(2));
    try std.testing.expectEqual(shrink_size, ia.capacity);
}

pub fn ExtIdMappedIdArray(T: type) type {
    return struct {
        arr: IdArray(T),
        map: std.AutoArrayHashMap(u32, u32),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .arr = IdArray(T).init(allocator),
                .map = std.AutoArrayHashMap(u32, u32).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.arr.deinit();
            self.map.deinit();
        }

        pub fn iterator(self: *const @This()) IdArray(T).Iterator {
            return self.arr.iterator();
        }

        pub fn boundedIterator(self: *const @This(), a: u32, b: u32) IdArray(T).Iterator {
            return self.arr.boundedIterator(a, b);
        }

        /// (Slow) Get item pointer by it's external id
        pub fn getByEid(self: *const @This(), eid: u32) ?*T {
            return if (self.map.get(eid)) |int_id| self.arr.at(int_id) else null;
        }

        /// (Fast) Get item pointer by it's internal id
        pub fn getById(self: *const @This(), id: u32) *T {
            return self.arr.at(id);
        }

        /// Returns internal id for quicker lookup
        pub fn put(self: *@This(), eid: u32, v: T) !u32 {
            const id = try self.arr.put(v);
            errdefer self.arr.remove(id);
            try self.map.putNoClobber(eid, id);
            return id;
        }

        /// Asserts that the key is valid
        pub fn remove(self: *@This(), eid: u32) void {
            const kv = self.map.fetchSwapRemove(eid) orelse unreachable;
            self.arr.remove(kv.value);
        }
    };
}

pub fn ShortStringMappedIdArray(T: type, comptime max_len: usize) type {
    return struct {
        const ShortString = std.BoundedArray(u8, max_len);
        const IdMap = std.ArrayHashMap(ShortString, u32, Ctx, true);

        const Ctx = struct {
            pub fn hash(_: @This(), k: ShortString) u32 {
                return @truncate(std.hash.Wyhash.hash(0, k.constSlice()));
            }

            pub fn eql(_: @This(), lhs: ShortString, rhs: ShortString, _: usize) bool {
                return std.mem.eql(u8, lhs.constSlice(), rhs.constSlice());
            }
        };

        arr: IdArray(T),
        map: std.ArrayHashMap(std.BoundedArray(u8, max_len), u32, Ctx, true),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .arr = IdArray(T).init(allocator),
                .map = IdMap.init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.arr.deinit();
            self.map.deinit();
        }

        pub fn iterator(self: *@This()) IdArray(T).Iterator {
            return self.arr.iterator();
        }

        /// (Slow) Get item pointer by it's external id
        pub fn getByEid(self: *const @This(), str: []const u8) ?*T {
            return if (self.map.get(ShortString.fromSlice(str) catch unreachable)) |int_id| self.arr.at(int_id) else null;
        }

        /// (Fast) Get item pointer by it's internal id
        pub fn getById(self: *const @This(), id: u32) *T {
            return self.arr.at(id);
        }

        /// Returns internal id for quicker lookup
        pub fn put(self: *@This(), str: []const u8, v: T) !u32 {
            const res = try self.map.getOrPut(try ShortString.fromSlice(str));
            if (res.found_existing) unreachable;
            errdefer self.map.orderedRemoveAt(res.index);
            const id = try self.arr.put(v);
            res.value_ptr.* = id;
            return id;
        }

        /// Asserts that the key is valid
        pub fn remove(self: *@This(), str: []const u8) void {
            const kv = self.map.fetchSwapRemove(ShortString.fromSlice(str) catch unreachable) orelse unreachable;
            self.arr.remove(kv.value);
        }
    };
}

test "ShortStringMappedIdArray" {
    var ssia = ShortStringMappedIdArray(usize, 32).init(std.testing.allocator);
    defer ssia.deinit();
    try std.testing.expectEqual(0, try ssia.put("kasia", 0));
    try std.testing.expectEqual(0, ssia.getByEid("kasia").?.*);
    ssia.remove("kasia");
}
