const std = @import("std");
const zvk = @import("zvk");

const DrawBuffer = @import("DrawBuffer.zig");
const shader_io = @import("shader_io.zig");

vertices: std.ArrayList(shader_io.Vertex),
buffer: DrawBuffer.Type(shader_io.Vertex),

pub fn init(device: *zvk.Device) !@This() {
    return .{
        .vertices = std.ArrayList(shader_io.Vertex).init(device.allocator),
        .buffer = try DrawBuffer.init(shader_io.Vertex, device, 64),
    };
}

pub fn deinit(self: @This()) void {
    self.vertices.deinit();
    self.buffer.deinit();
}

pub fn pushVertices(self: *@This(), data: []const shader_io.Vertex) !void {
    try self.vertices.appendSlice(data);
}

pub fn clear(self: *@This()) void {
    self.vertices.clearRetainingCapacity();
}

pub fn bufferData(self: *@This()) !bool {
    const invalidated = try self.buffer.bufferData(self.vertices.items);
    try self.buffer.flush(0, @intCast(std.mem.sliceAsBytes(self.vertices.items).len));
    return invalidated;
}
