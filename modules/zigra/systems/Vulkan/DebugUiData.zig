const std = @import("std");
const zvk = @import("zvk");

const DrawBuffer = @import("DrawBuffer.zig");
const shader_io = @import("shader_io.zig");

vertices: std.ArrayList(shader_io.Vertex),
blocks: std.ArrayList(GuiBlock),
buffer: DrawBuffer.Type(shader_io.Vertex),

pub const GuiBlock = union(enum) {
    pub const Scissor = struct {
        extent: @Vector(2, u32),
        offset: @Vector(2, i32),
    };

    pub const Indices = struct {
        begin: u32,
        len: u32,
    };

    scissor: Scissor,
    triangles: Indices,
};

pub fn init(device: *zvk.Device) !@This() {
    return .{
        .vertices = std.ArrayList(shader_io.Vertex).init(device.allocator),
        .blocks = std.ArrayList(GuiBlock).init(device.allocator),
        .buffer = try DrawBuffer.init(shader_io.Vertex, device, 256),
    };
}

pub fn deinit(self: @This()) void {
    self.vertices.deinit();
    self.blocks.deinit();
    self.buffer.deinit();
}

pub fn pushVertices(self: *@This(), data: []const shader_io.Vertex) !void {
    const last_ptr = switch (self.blocks.items.len) {
        else => &self.blocks.items[self.blocks.items.len - 1],
        0 => null,
    };

    const new_block = if (last_ptr) |last_blk| blk: switch (last_blk.*) {
        .triangles => |*b| {
            b.len += @intCast(data.len);
            break :blk false;
        },
        else => true,
    } else true;

    if (new_block) try self.blocks.append(.{
        .triangles = .{
            .begin = @intCast(self.vertices.items.len),
            .len = @intCast(data.len),
        },
    });

    try self.vertices.appendSlice(data);
}

pub fn pushScissor(self: *@This(), scissor: GuiBlock.Scissor) !void {
    var new_scissor = scissor;

    inline for (0..2) |i| if (new_scissor.offset[i] < 0) {
        new_scissor.extent[i] -|= @intCast(-scissor.offset[i]);
        new_scissor.offset[i] = 0;
    };

    const last_ptr = switch (self.blocks.items.len) {
        else => &self.blocks.items[self.blocks.items.len - 1],
        0 => null,
    };

    if (last_ptr) |last_blk| switch (last_blk.*) {
        .scissor => |*s| {
            s.* = new_scissor;
            return;
        },
        else => {},
    };

    try self.blocks.append(.{ .scissor = new_scissor });
}

pub fn clear(self: *@This()) void {
    self.blocks.clearRetainingCapacity();
    self.vertices.clearRetainingCapacity();
}

pub fn bufferData(self: *@This()) !bool {
    const invalidated = try self.buffer.bufferData(self.vertices.items);
    try self.buffer.flush(0, self.buffer.buffer.options.size);
    return invalidated;
}
