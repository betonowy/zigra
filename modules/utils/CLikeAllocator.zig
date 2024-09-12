const std = @import("std");

allocator: std.mem.Allocator,

const default_alignment = 16;

const Metadata = struct {
    info_ptr: *BlockHeader,
    user_data: []u8,

    const BlockHeader = packed struct {
        len: u32,
        block_offset: u16,
        alignment: u16,
    };

    pub fn fromUserPtr(user_ptr: *anyopaque) @This() {
        const block_header_ptr: *BlockHeader = @ptrFromInt(@as(usize, @intFromPtr(user_ptr)) - 8);
        return .{ .info_ptr = block_header_ptr, .user_data = @as([*]u8, @ptrCast(user_ptr))[0..block_header_ptr.len] };
    }

    pub fn install(buf: []u8, size: usize, alignment: usize) @This() {
        const origin_address: usize = @intFromPtr(buf.ptr);
        const user_data_start = std.mem.alignForward(usize, origin_address + @sizeOf(BlockHeader), alignment);
        const block_header_start = user_data_start - 8;

        const block_header_ptr: *BlockHeader = @ptrFromInt(block_header_start);

        block_header_ptr.* = .{
            .len = @intCast(size),
            .block_offset = @intCast(block_header_start - origin_address),
            .alignment = @intCast(alignment),
        };

        return .{ .info_ptr = block_header_ptr, .user_data = @as([*]u8, @ptrFromInt(user_data_start))[0..size] };
    }

    pub fn origin(self: @This()) []u8 {
        const ptr: [*]u8 = @ptrFromInt(@as(usize, @intFromPtr(self.info_ptr)) - self.info_ptr.block_offset);
        return ptr[0 .. self.info_ptr.len + requiredExtension(self.info_ptr.alignment)];
    }

    pub fn requiredExtension(alignment: usize) usize {
        return alignment + @sizeOf(BlockHeader);
    }
};

pub fn castFromPtr(ptr: *anyopaque) *@This() {
    return @alignCast(@ptrCast(ptr));
}

pub fn allocOpt(self: @This(), size: usize) ?*anyopaque {
    return self.alloc(size) catch null;
}

pub fn alloc(self: @This(), size: usize) !*anyopaque {
    return self.allocAlign(size, default_alignment);
}

pub fn allocAlign(self: @This(), size: usize, alignment: usize) !*anyopaque {
    const origin = try self.allocator.alloc(u8, size + Metadata.requiredExtension(alignment));
    const metadata = Metadata.install(origin, size, alignment);
    return metadata.user_data.ptr;
}

pub fn reallocOpt(self: @This(), prev: *anyopaque, size: usize) ?*anyopaque {
    return self.realloc(prev, size) catch null;
}

pub fn realloc(self: @This(), prev: *anyopaque, size: usize) !*anyopaque {
    return self.reallocAlign(prev, size, default_alignment);
}

pub fn reallocAlign(self: @This(), prev: *anyopaque, size: usize, alignment: usize) !*anyopaque {
    const origin = try self.allocator.alloc(u8, size + Metadata.requiredExtension(alignment));
    const metadata = Metadata.install(origin, size, alignment);
    const old_view = Metadata.fromUserPtr(prev);

    const copy_range = @min(metadata.user_data.len, old_view.user_data.len);
    @memcpy(metadata.user_data[0..copy_range], old_view.user_data[0..copy_range]);

    self.free(prev);
    return metadata.user_data.ptr;
}

pub fn free(self: @This(), memory: *anyopaque) void {
    self.allocator.free(Metadata.fromUserPtr(memory).origin());
}

test "functionality" {
    const helper = struct {
        pub fn anyView(ptr: *anyopaque, size: usize) []u8 {
            return @as([*]u8, @ptrCast(ptr))[0..size];
        }
    };

    const self = @This(){ .allocator = std.testing.allocator };

    var buffer = helper.anyView(try self.allocAlign(8, 2), 8);
    defer self.free(buffer.ptr);
    @memset(buffer, 21);

    buffer = helper.anyView(try self.reallocAlign(buffer.ptr, 4, 16), 4);
    try std.testing.expectEqualSlices(u8, &.{ 21, 21, 21, 21 }, buffer);

    buffer = helper.anyView(try self.reallocAlign(buffer.ptr, 8, 4), 8);
    try std.testing.expectEqualSlices(u8, &.{ 21, 21, 21, 21 }, buffer[0..4]);
    @memset(buffer, 77);
}
