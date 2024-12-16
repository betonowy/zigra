//
// This all is probably a stupid idea considering how little
// zig supports it and how little I care about it.
//

const std = @import("std");

/// Deinits container. Calls `deinit()` on every element if it has it.
pub fn deinitMM(container: anytype) void {
    for (container.items[0..]) |*item| {
        if (std.meta.hasMethod(@TypeOf(item), "deinit")) item.deinit();
    }
    container.deinit();
}

test deinitMM {
    const Deinitable = struct {
        ref: *usize,

        pub fn deinit(self: *@This()) void {
            self.ref.* -= 1;
        }
    };

    var ref: usize = 1;
    var al = std.ArrayList(Deinitable).init(std.testing.allocator);
    try al.append(Deinitable{ .ref = &ref });
    deinitMM(al);
    try std.testing.expectEqual(0, ref);
}

/// Deinits unmanaged container. Calls `deinit()` on every element if it has it.
pub fn deinitUM(unmanaged_container: anytype, container_allocator: std.mem.Allocator) void {
    for (unmanaged_container.items[0..]) |*item| {
        if (std.meta.hasMethod(@TypeOf(item), "deinit")) item.deinit();
    }
    unmanaged_container.deinit(container_allocator);
}

test deinitUM {
    const Deinitable = struct {
        ref: *usize,

        pub fn deinit(self: *@This()) void {
            self.ref.* -= 1;
        }
    };

    var ref: usize = 1;
    var al = std.ArrayListUnmanaged(Deinitable){};
    try al.append(std.testing.allocator, Deinitable{ .ref = &ref });
    deinitUM(&al, std.testing.allocator);
    try std.testing.expectEqual(0, ref);
}

/// Deinits container. Calls `deinit(item_allocator)` on every element if it has it.
pub fn deinitMU(container: anytype, item_allocator: std.mem.Allocator) void {
    for (container.items[0..]) |*item| {
        if (std.meta.hasMethod(@TypeOf(item), "deinit")) item.deinit(item_allocator);
    }
    container.deinit();
}

test deinitMU {
    const Deinitable = struct {
        ref: *usize,

        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.ref.* -= 1;
        }
    };

    var ref: usize = 1;
    var al = std.ArrayList(Deinitable).init(std.testing.allocator);
    try al.append(Deinitable{ .ref = &ref });
    deinitMU(al, std.testing.allocator);
    try std.testing.expectEqual(0, ref);
}

/// Deinits unmanaged container. Calls `deinit(item_allocator)` on every element if it has it.
pub fn deinitUU(
    unmanaged_container: anytype,
    container_allocator: std.mem.Allocator,
    item_allocator: std.mem.Allocator,
) void {
    for (unmanaged_container.items[0..]) |*item| {
        if (std.meta.hasMethod(@TypeOf(item), "deinit")) item.deinit(item_allocator);
    }
    unmanaged_container.deinit(container_allocator);
}

test deinitUU {
    const Deinitable = struct {
        ref: *usize,

        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.ref.* -= 1;
        }
    };

    var ref: usize = 1;
    var al = std.ArrayListUnmanaged(Deinitable){};
    try al.append(std.testing.allocator, Deinitable{ .ref = &ref });
    deinitUU(&al, std.testing.allocator, std.testing.allocator);
    try std.testing.expectEqual(0, ref);
}

/// Deinits container holding slices. Frees every slice in it.
pub fn deinitMS(container: anytype, slice_allocator: std.mem.Allocator) void {
    for (container.items) |item| slice_allocator.free(item);
    container.deinit();
}

test deinitMS {
    var al = std.ArrayList([]u8).init(std.testing.allocator);
    try al.append(try std.testing.allocator.alloc(u8, 8));
    deinitMS(al, std.testing.allocator);
}

/// Deinits container holding pointers. Frees every pointer in it.
pub fn deinitMI(container: anytype, item_allocator: std.mem.Allocator) void {
    for (container.items) |item| item_allocator.destroy(item);
    container.deinit();
}

test deinitMI {
    var al = std.ArrayList(*u8).init(std.testing.allocator);
    try al.append(try std.testing.allocator.create(u8));
    deinitMI(al, std.testing.allocator);
}
