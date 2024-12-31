const std = @import("std");
const zvk = @import("zvk");

const DrawBuffer = @import("DrawBuffer.zig");
const shader_io = @import("shader_io.zig");

vertices: std.ArrayList(shader_io.Vertex),
buffer: DrawBuffer.Type(shader_io.Vertex),

pub fn init(device: *zvk.Device) !@This() {
    return .{
        .vertices = std.ArrayList(shader_io.Vertex).init(device.allocator),
        .buffer = try DrawBuffer.init(shader_io.Vertex, device, 0x10000),
    };
}

pub fn deinit(self: @This()) void {
    self.vertices.deinit();
    self.buffer.deinit();
}

pub fn pushTriangles(self: *@This(), data: []const shader_io.Vertex) !void {
    try self.vertices.appendSlice(data);
}

pub fn clear(self: *@This()) void {
    self.vertices.clearRetainingCapacity();
}

pub fn cmdUpdateHostToDevice(self: *@This(), cmd_buf: zvk.CommandBuffer) !void {
    try self.buffer.bufferData(self.vertices.items);
    try self.buffer.cmdUpdateHostToDevice(cmd_buf);
}
