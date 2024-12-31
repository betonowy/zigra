const std = @import("std");

const zvk = @import("zvk");

pub fn init(T: type, device: *zvk.Device, initial_size: usize) !Type(T) {
    const size_in_bytes = @sizeOf(T) * initial_size;

    const device_buffer = try zvk.Buffer.init(device, .{
        .properties = .{ .device_local_bit = true },
        .size = size_in_bytes,
        .usage = .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
    });
    errdefer device_buffer.deinit();

    const host_buffer = try device_buffer.createStagingBuffer(.{
        .usage = .{ .transfer_src_bit = true },
    });

    return .{
        .host_buffer = host_buffer,
        .device_buffer = device_buffer,
    };
}

pub fn Type(T: type) type {
    return struct {
        host_buffer: zvk.Buffer,
        device_buffer: zvk.Buffer,

        pub fn deinit(self: @This()) void {
            self.host_buffer.deinit();
            self.device_buffer.deinit();
        }

        pub fn getDescriptorSetWrite(
            self: @This(),
            set: zvk.DescriptorSet,
            binding: u32,
        ) zvk.DescriptorSet.Write {
            return self.host_buffer.getDescriptorSetWrite(set, .{
                .binding = binding,
                .type = .storage_buffer,
            });
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

        pub fn bufferData(self: *@This(), data: []const T) !void {
            const data_bytes: []const u8 = std.mem.sliceAsBytes(data);
            if (self.host_buffer.options.size < data_bytes.len) try self.expand(@intCast(data_bytes.len));
            const map = self.host_buffer.map orelse try self.host_buffer.mapMemory();
            @memcpy(map[0..data_bytes.len], data_bytes);
        }

        fn expand(self: *@This(), minimum_size: u64) !void {
            if (minimum_size > 1 << 60) return error.ExpandSizeTooBig;
            var new_size = self.host_buffer.options.size;
            while (new_size < minimum_size) new_size <<= 1;
            try self.host_buffer.resizeFast(new_size);
            try self.device_buffer.resizeFast(new_size);

            @panic("This currently doesn't work though");
        }
    };
}
