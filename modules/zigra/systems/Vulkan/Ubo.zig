const std = @import("std");

const zvk = @import("zvk");
const shader_io = @import("shader_io.zig");

device_buffer: zvk.Buffer,
host_buffer: zvk.Buffer,
p_host: *shader_io.Ubo,

pub fn init(device: *zvk.Device) !@This() {
    const device_buffer = try zvk.Buffer.init(device, .{
        .properties = .{ .device_local_bit = true },
        .size = @sizeOf(shader_io.Ubo),
        .usage = .{ .transfer_dst_bit = true, .uniform_buffer_bit = true },
    });
    errdefer device_buffer.deinit();

    var host_buffer = try device_buffer.createStagingBuffer(.{
        .usage = .{ .transfer_src_bit = true },
    });
    errdefer host_buffer.deinit();

    const map = try host_buffer.mapMemory();

    return .{
        .device_buffer = device_buffer,
        .host_buffer = host_buffer,
        .p_host = @alignCast(@ptrCast(map)),
    };
}

pub fn deinit(self: @This()) void {
    self.host_buffer.deinit();
    self.device_buffer.deinit();
}

pub fn cmdUpdateHostToDevice(self: *@This(), cmd_buf: zvk.CommandBuffer) !void {
    cmd_buf.cmdPipelineBarrier(.{
        .buffer = &.{
            self.host_buffer.barrier(.{
                .dst_access_mask = .{ .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
            }),
            self.device_buffer.barrier(.{
                .src_access_mask = .{ .memory_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
            }),
        },
    });

    try cmd_buf.cmdBufferCopy(.{ .src = self.host_buffer, .dst = self.device_buffer });

    cmd_buf.cmdPipelineBarrier(.{
        .buffer = &.{
            self.device_buffer.barrier(.{
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
            }),
        },
    });
}

pub fn getDescriptorSetWrite(
    self: @This(),
    set: zvk.DescriptorSet,
    binding: u32,
) zvk.DescriptorSet.Write {
    return self.device_buffer.getDescriptorSetWrite(set, .{
        .binding = binding,
        .type = .uniform_buffer,
    });
}
