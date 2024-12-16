const std = @import("std");
const builtin = @import("builtin");

const IdArray = @import("id_containers.zig").IdArray;

pub const Player = u4;
pub const Index = u20;
pub const Generation = u40;

pub const UuidDescriptor = struct { player: Player, gen: Generation };

pub const Uuid = packed struct {
    index: Index = 0,
    player: Player = 0,
    gen: Generation = 0,
};

pub const UuidGenerator = struct {
    gen: std.atomic.Value(u64) = .{ .raw = 0 },

    pub fn next(self: *@This()) Generation {
        return std.math.cast(Generation, self.gen.fetchAdd(1, .monotonic)) orelse @panic("Gen overflow");
    }
};

pub fn UuidMaster(T: type) type {
    return struct {
        arr: Array,

        const Payload = struct { descriptor: UuidDescriptor, data: T };
        const Array = IdArray(Payload);

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .arr = Array.init(allocator) };
        }

        pub fn deinit(self: @This()) void {
            self.arr.deinit();
        }

        pub fn iterator(self: *const @This()) Array.Iterator {
            return self.arr.iterator();
        }

        pub fn boundedIterator(self: *const @This(), a: u32, b: u32) Array.Iterator {
            return self.arr.boundedIterator(a, b);
        }

        pub fn create(self: *@This(), generator: *UuidGenerator, player: Player, value: T) !Uuid {
            const generation = generator.next();

            const id = std.math.cast(u20, try self.arr.put(.{
                .descriptor = .{
                    .gen = generation,
                    .player = player,
                },
                .data = value,
            })) orelse @panic("UuidIdOverflow");

            return .{
                .index = id,
                .player = player,
                .gen = generation,
            };
        }

        pub fn destroy(self: *@This(), uuid: Uuid) !void {
            const payload = self.arr.tryAt(uuid.index) orelse return error.UuidDoesNotExist;
            if (payload.descriptor.gen != uuid.gen or payload.descriptor.player != uuid.player) return error.UuidDoesNotExist;
            self.arr.remove(uuid.index);
        }

        pub fn exists(self: *const @This(), uuid: Uuid) bool {
            const payload = self.arr.tryAt(uuid.index) orelse return false;
            return payload.descriptor.gen == uuid.gen or payload.descriptor.player == uuid.player;
        }

        pub fn get(self: *const @This(), uuid: Uuid) ?*T {
            const payload = self.arr.tryAt(uuid.index) orelse return null;
            if (payload.descriptor.gen != uuid.gen or payload.descriptor.player != uuid.player) return null;
            return &self.arr.at(uuid.index).data;
        }
    };
}

test UuidMaster {
    var gen = UuidGenerator{};
    var master = UuidMaster(void).init(std.testing.allocator);
    defer master.deinit();

    const uuid0 = try master.create(&gen, 1, {});
    const uuid1 = try master.create(&gen, 2, {});

    try std.testing.expectEqual(1, uuid0.player);
    try std.testing.expectEqual(2, uuid1.player);
    try std.testing.expectEqual(0, uuid0.index);
    try std.testing.expectEqual(1, uuid1.index);

    try master.destroy(uuid0);
    try master.destroy(uuid1);
    try std.testing.expectError(error.UuidDoesNotExist, master.destroy(uuid0));
    try std.testing.expectError(error.UuidDoesNotExist, master.destroy(uuid1));

    const uuid2 = try master.create(&gen, 1, {});
    const uuid3 = try master.create(&gen, 2, {});

    try std.testing.expectEqual(uuid0.index, uuid2.index);
    try std.testing.expectEqual(uuid1.index, uuid3.index);
    try std.testing.expectEqual(uuid0.player, uuid2.player);
    try std.testing.expectEqual(uuid1.player, uuid3.player);
    try std.testing.expect(uuid0 != uuid2);
    try std.testing.expect(uuid1 != uuid3);
}

pub fn UuidContainer(T: type) type {
    return struct {
        arr: IdArray(T),
        map: std.AutoArrayHashMap(Uuid, u32),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .arr = IdArray(T).init(allocator),
                .map = std.AutoArrayHashMap(Uuid, u32).init(allocator),
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

        /// Safely gets pointer to value, null if it does not exist
        pub fn getByUuid(self: *const @This(), uuid: Uuid) ?*T {
            return self.arr.at(self.map.get(uuid) orelse return null);
        }

        /// Asserts that valid object exists in the array
        pub fn getById(self: *const @This(), id: u32) *T {
            return self.arr.at(id);
        }

        /// Returns new uuid of the generated value
        pub fn tryPut(self: *@This(), uuid: Uuid, v: T) !u32 {
            const id = try self.arr.put(v);
            errdefer self.arr.remove(id);
            try self.map.putNoClobber(uuid, id);
            return id;
        }

        /// Removes value associated with uuid if it exists
        pub fn remove(self: *@This(), uuid: Uuid) !void {
            const kv = self.map.fetchSwapRemove(uuid) orelse return error.UuidDoesNotExist;
            self.arr.remove(kv.value);
        }
    };
}

test UuidContainer {
    const Container = UuidContainer(usize);
    var container = Container.init(std.testing.allocator);
    defer container.deinit();

    var gen = UuidGenerator{};
    var master = UuidMaster(void).init(std.testing.allocator);
    defer master.deinit();

    const uuid0 = try master.create(&gen, 0, {});
    const uuid1 = try master.create(&gen, 0, {});
    const uuid2 = try master.create(&gen, 0, {});

    const id0 = try container.tryPut(uuid0, 0);
    try std.testing.expectEqual(0, container.getById(id0).*);

    const id1 = try container.tryPut(uuid1, 1);
    try std.testing.expectEqual(1, container.getById(id1).*);

    const id2 = try container.tryPut(uuid2, 2);
    try std.testing.expectEqual(2, container.getById(id2).*);

    try container.remove(uuid1);
    try std.testing.expectError(error.UuidDoesNotExist, container.remove(uuid1));

    try std.testing.expectEqual(0, container.getByUuid(uuid0).?.*);
    try std.testing.expectEqual(null, container.getByUuid(uuid1));
    try std.testing.expectEqual(2, container.getByUuid(uuid2).?.*);
}
