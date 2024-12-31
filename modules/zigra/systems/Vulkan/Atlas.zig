const std = @import("std");

const la = @import("la");
const zvk = @import("zvk");
const stb = @cImport(@cInclude("stb/stb_image.h"));
// TODO Refactor stb here in favor of an externally provided decoder.
//      Vulkan atlas should not care about image file formats at all.

pub const max_layers = 16;

map: std.StringArrayHashMap(TextureReference),
layers: std.BoundedArray(TextureLayer, max_layers),

pub const TextureReference = struct { layer: u32, index: u32 };

pub const TextureLayer = struct {
    allocator: std.mem.Allocator,
    image: zvk.Image,
    view: zvk.ImageView,
    last_index: u32 = 0,

    device: *zvk.Device,
    cmd_pool: zvk.CommandPool,
    cmd: zvk.CommandBuffer,

    pub fn init(device: *zvk.Device, n_slots: u32, new_extent: @Vector(2, u32)) !@This() {
        const image = try zvk.Image.init(device, .{
            .array_layers = n_slots,
            .extent = la.extend(new_extent, .{1}),
            .format = .r8g8b8a8_srgb,
            .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
        });
        errdefer image.deinit();

        const view = try zvk.ImageView.init(image);
        errdefer view.deinit();

        const cmd_pool = try zvk.CommandPool.init(device, .{
            .queue_family = device.queue_gpu_comp.family,
            .flags = .{ .reset_command_buffer_bit = true },
        });

        const cmd = try zvk.CommandBuffer.init(cmd_pool, .primary);

        return .{
            .image = image,
            .view = view,
            .allocator = device.allocator,
            .cmd_pool = cmd_pool,
            .cmd = cmd,
            .device = device,
        };
    }

    pub fn deinit(self: @This()) void {
        self.cmd.deinit();
        self.cmd_pool.deinit();
        self.image.deinit();
        self.view.deinit();
    }

    pub fn uploadSlot(self: *@This(), data: []const u8) !u32 {
        const bytes_per_pixel = switch (self.image.options.format) {
            .r8g8b8a8_srgb => 4,
            else => return error.UnsupportedFormat,
        };

        const expected_size = @reduce(.Mul, self.image.options.extent) * bytes_per_pixel;

        if (expected_size != data.len) return error.DataSizeMismatch;

        var staging_image = try self.image.createStagingImage(.{ .layers = 1 });
        defer staging_image.deinit();

        const map = try staging_image.mapMemory();

        @memcpy(map[0..data.len], data);

        try self.cmd.reset();
        try self.cmd.begin(.{ .flags = .{ .one_time_submit_bit = true } });

        self.cmd.cmdPipelineBarrier(.{
            .image = &.{
                staging_image.barrier(.{
                    .src_layout = .preinitialized,
                    .dst_layout = .transfer_src_optimal,
                }),
                self.image.barrier(.{
                    .src_stage_mask = .{ .all_commands_bit = true },
                    .dst_stage_mask = .{ .all_commands_bit = true },
                    .src_access_mask = .{ .memory_read_bit = true },
                    .dst_access_mask = .{ .memory_write_bit = true },
                    .src_layout = .undefined,
                    .dst_layout = .transfer_dst_optimal,
                }),
            },
        });

        try self.cmd.cmdImageCopy(.{
            .src = staging_image,
            .dst = self.image,
            .src_layout = .transfer_src_optimal,
            .dst_layout = .transfer_dst_optimal,
            .regions = &.{.{
                .src_subresource = .{
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .dst_subresource = .{
                    .base_array_layer = self.last_index,
                    .layer_count = 1,
                },
            }},
        });

        self.cmd.cmdPipelineBarrier(.{
            .image = &.{self.image.barrier(.{
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .src_layout = .transfer_dst_optimal,
                .dst_layout = .shader_read_only_optimal,
                .subresource_range = .{
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            })},
        });

        try self.cmd.end();

        const fence = try zvk.Fence.init(self.cmd.device, false);
        defer fence.deinit();

        try self.device.queue_gpu_comp.submit(.{ .cmds = &.{self.cmd}, .fence = fence });
        try fence.wait();

        defer self.last_index += 1;
        return self.last_index;
    }

    pub fn extent(self: @This()) @Vector(2, u32) {
        return .{
            self.image.options.extent.width,
            self.image.options.extent.height,
        };
    }

    pub fn getDescriptorSetWrite(
        self: @This(),
        set: zvk.DescriptorSet,
        sampler: zvk.Sampler,
        binding: u32,
        index: u32,
    ) zvk.DescriptorSet.Write {
        return self.view.getDescriptorSetWrite(set, .{
            .index = index,
            .binding = binding,
            .layout = .shader_read_only_optimal,
            .sampler = sampler,
            .type = .combined_image_sampler,
        });
    }
};

pub fn init(device: *zvk.Device, paths: []const []const u8, decoder: anytype) !@This() {
    _ = decoder; // autofix
    var extents = std.ArrayList(struct { extent: @Vector(2, u32), count: u32 }).init(device.allocator);
    defer extents.deinit();

    for (paths) |path| {
        const size = try readPngSize(path);

        blk: {
            for (extents.items) |*e| if (@reduce(.And, e.extent == size)) {
                e.count += 1;
                break :blk;
            };

            try extents.append(.{ .extent = size, .count = 1 });
        }
    }

    if (extents.items.len > max_layers) return error.MoreExtentsThanMaxLayers;

    var layers = std.BoundedArray(TextureLayer, max_layers){};
    errdefer for (layers.constSlice()) |l| l.deinit();

    for (extents.items) |e| {
        const tl = try TextureLayer.init(device, e.count, e.extent);
        errdefer tl.deinit();
        layers.appendAssumeCapacity(tl);
    }

    var map = std.StringArrayHashMap(TextureReference).init(device.allocator);
    errdefer map.deinit();

    for (paths) |path| {
        const size = try readPngSize(path);

        for (layers.slice(), 0..) |*l, i| {
            if (@reduce(.Or, l.image.options.extent != la.extend(size, .{1}))) continue;

            const data = try loadPng(path);
            defer freePng(data);

            try map.put(path, .{
                .index = try l.uploadSlot(data),
                .layer = @intCast(i),
            });

            break;
        }
    }

    return .{ .layers = layers, .map = map };
}

pub fn deinit(self: *@This()) void {
    self.map.deinit();
    for (self.layers.constSlice()) |l| l.deinit();
}

pub fn getRectIdByPath(self: @This(), path: []const u8) ?TextureReference {
    return self.map.get(path);
}

// TODO should be @Vector(2, u32)
pub fn getRectById(self: @This(), ref: TextureReference) @import("vk").Rect2D {
    const im = self.layers.constSlice()[ref.layer].image.options.extent;
    return .{
        .extent = .{ .width = im[0], .height = im[1] },
        .offset = .{
            .x = 0,
            .y = 0,
        },
    };
}

pub fn WriteResult(len: comptime_int) type {
    return std.BoundedArray(zvk.DescriptorSet.Write, len);
}

pub fn getDescriptorSetWrite(
    self: @This(),
    set: zvk.DescriptorSet,
    sampler: zvk.Sampler,
    binding: u32,
) !WriteResult(max_layers) {
    var writes = WriteResult(max_layers){};

    for (self.layers.constSlice(), 0..) |layer, i| {
        try writes.append(layer.getDescriptorSetWrite(set, sampler, binding, @intCast(i)));
    }

    return writes;
}
fn readPngSize(path: []const u8) !@Vector(2, u32) {
    const Header = extern struct {
        magic: [8]u8,
        _: [4]u8,
        ihdr: [4]u8,
        width: [4]u8,
        height: [4]u8,
    };

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: Header = undefined;
    if (try file.read(std.mem.asBytes(&header)) != @sizeOf(Header)) return error.BadFormat;

    if (!std.mem.eql(u8, header.magic[0..], "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A")) return error.BadFormat;
    if (!std.mem.eql(u8, header.ihdr[0..], "\x49\x48\x44\x52")) return error.BadFormat;

    return .{
        std.mem.readPackedIntForeign(u32, header.width[0..], 0),
        std.mem.readPackedIntForeign(u32, header.height[0..], 0),
    };
}

fn loadPng(path: []const u8) ![]u8 {
    var heap: [std.fs.max_path_bytes + 1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&heap);
    const c_str = try fixed.allocator().dupeZ(u8, path);

    var x: c_int = undefined;
    var y: c_int = undefined;
    var c: c_int = undefined;

    const stb_mem = stb.stbi_load(c_str.ptr, &x, &y, &c, 4) orelse return error.StbError;
    return @as([*]u8, @ptrCast(stb_mem))[0..@intCast(x * y * c)];
}

fn freePng(data: []u8) void {
    stb.stbi_image_free(data.ptr);
}
