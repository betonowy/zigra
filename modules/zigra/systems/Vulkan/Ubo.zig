const std = @import("std");

const zvk = @import("zvk");
const shader_io = @import("shader_io.zig");

device: *zvk.Device,
buffer: zvk.Buffer,
p_host: *shader_io.Ubo,

pub fn init(device: *zvk.Device) !@This() {
    var buffer = blk: {
        var buf_options = zvk.Buffer.InitOptions{
            .usage = .{ .uniform_buffer_bit = true },
            .size = @sizeOf(shader_io.Ubo),
        };

        // BAR memory has no gain for now

        buf_options.properties = .{
            .host_visible_bit = true,
            .device_local_bit = true,
        };

        if (zvk.Buffer.init(device, buf_options)) |buf| break :blk buf else |_| {}

        buf_options.properties = .{
            .host_visible_bit = true,
            .host_cached_bit = true,
        };

        if (zvk.Buffer.init(device, buf_options)) |buf| break :blk buf else |_| {}

        buf_options.properties = .{
            .host_visible_bit = true,
        };

        break :blk try zvk.Buffer.init(device, buf_options);
    };
    errdefer buffer.deinit();

    const map = try buffer.mapMemory();

    return .{
        .device = device,
        .buffer = buffer,
        .p_host = @alignCast(@ptrCast(map)),
    };
}

pub fn deinit(self: @This()) void {
    self.buffer.deinit();
}

pub fn flush(self: @This()) !void {
    try self.buffer.flush(0, @sizeOf(shader_io.Ubo));
}

pub fn getDescriptorSetWrite(
    self: @This(),
    set: zvk.DescriptorSet,
    binding: u32,
) zvk.DescriptorSet.Write {
    return self.buffer.getDescriptorSetWrite(set, .{
        .binding = binding,
        .type = .uniform_buffer,
    });
}
