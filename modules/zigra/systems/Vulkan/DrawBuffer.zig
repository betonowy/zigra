const std = @import("std");

const zvk = @import("zvk");

pub fn init(T: type, device: *zvk.Device, initial_size: usize) !Type(T) {
    const size_in_bytes = @sizeOf(T) * initial_size;

    const buffer = blk: {
        var buf_options = zvk.Buffer.InitOptions{
            .usage = .{ .storage_buffer_bit = true },
            .size = size_in_bytes,
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

    return .{
        .device = device,
        .buffer = buffer,
    };
}

pub fn Type(T: type) type {
    return struct {
        device: *zvk.Device,
        buffer: zvk.Buffer,

        pub fn deinit(self: @This()) void {
            self.buffer.deinit();
        }

        pub fn getDescriptorSetWrite(
            self: @This(),
            set: zvk.DescriptorSet,
            binding: u32,
        ) zvk.DescriptorSet.Write {
            return self.buffer.getDescriptorSetWrite(set, .{
                .binding = binding,
                .type = .storage_buffer,
            });
        }

        pub fn flush(self: @This(), offset: u64, size: u64) !void {
            return self.buffer.flush(offset, size);
        }

        pub fn bufferData(self: *@This(), data: []const T) !bool {
            const data_bytes: []const u8 = std.mem.sliceAsBytes(data);

            var invalidated = false;

            if (self.buffer.options.size < data_bytes.len) {
                try self.expand(@intCast(data_bytes.len));
                invalidated = true;
            }

            const map = self.buffer.map orelse try self.buffer.mapMemory();
            @memcpy(map[0..data_bytes.len], data_bytes);

            return invalidated;
        }

        fn expand(self: *@This(), minimum_size: u64) !void {
            if (minimum_size > 1 << 60) return error.ExpandSizeTooBig;
            var new_size = self.buffer.options.size;
            while (new_size < minimum_size) new_size <<= 1;
            try self.buffer.resizeFast(new_size);
        }
    };
}
