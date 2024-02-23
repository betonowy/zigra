const std = @import("std");
const vk = @import("vk.zig");
const types = @import("vulkan_types.zig");
const VulkanBackend = @import("VulkanBackend.zig");
const meta = @import("meta.zig");

const stb = @cImport(@cInclude("stb/stb_image.h"));

map: std.StringArrayHashMap(vk.Rect2D),
image: types.ImageData,
sampler: vk.Sampler,

pub fn init(backend: *VulkanBackend, paths: []const []const u8) !@This() {
    var extents = std.ArrayList(vk.Extent2D).init(backend.allocator);
    defer extents.deinit();

    for (paths) |path| try extents.append(try readPngSize(path));

    var rects = std.ArrayList(vk.Rect2D).init(backend.allocator);
    defer rects.deinit();
    try rects.resize(extents.items.len);

    for (extents.items, rects.items, 0..) |extent, *rect, i| {
        rect.* = findFreeRect(extent, rects.items[0..i], .{ .width = 2048, .height = 2048 }) orelse {
            return error.OutOfAtlasSpace;
        };
    }

    var self: @This() = undefined;
    self.map = std.StringArrayHashMap(vk.Rect2D).init(backend.allocator);
    errdefer {
        var it = self.map.iterator();
        while (it.next()) |next| self.map.allocator.free(next.key_ptr.*);
        self.map.deinit();
    }

    const required_extent = calculateRequiredExtent(rects.items);

    const staging_image = try backend.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = required_extent,
        .format = .r8g8b8a8_srgb,
        .initial_layout = .preinitialized,
        .property = .{ .host_visible_bit = true, .host_coherent_bit = true },
        .usage = .{ .transfer_src_bit = true },
        .tiling = .linear,
        .has_view = false,
        .map_memory = true,
    });
    defer backend.destroyImage(staging_image);

    for (paths, rects.items) |path, rect| {
        var heap: [1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&heap);
        const c_str = try fixed.allocator().allocSentinel(u8, path.len, 0);
        @memcpy(c_str[0..], path[0..]);

        var x: c_int = undefined;
        var y: c_int = undefined;
        var c: c_int = undefined;

        const stb_mem = stb.stbi_load(c_str.ptr, &x, &y, &c, 4);
        defer stb.stbi_image_free(stb_mem);

        const src: [*]u8 = @ptrCast(stb_mem);
        const dst: [*]u8 = @ptrCast(staging_image.map orelse unreachable);

        for (0..@intCast(y)) |dst_y| {
            const dst_x_start: usize = @intCast(4 * rect.offset.x);
            const dst_y_start: usize = @intCast(4 * required_extent.width * (dst_y + @as(u32, @intCast(rect.offset.y))));
            const slice_src = (src + 4 * rect.extent.width * dst_y)[0 .. rect.extent.width * 4];
            const slice_dst = (dst + dst_x_start + dst_y_start)[0 .. rect.extent.width * 4];
            @memcpy(slice_dst, slice_src);
        }
    }

    self.image = try backend.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = required_extent,
        .format = .r8g8b8a8_srgb,
        .initial_layout = .undefined,
        .property = .{ .device_local_bit = true },
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .tiling = .optimal,
    });
    errdefer backend.destroyImage(self.image);

    var cmd: vk.CommandBuffer = undefined;

    try backend.vkd.allocateCommandBuffers(backend.device, &.{
        .command_buffer_count = 1,
        .command_pool = backend.graphic_command_pool,
        .level = .primary,
    }, meta.asArray(&cmd));

    defer backend.vkd.freeCommandBuffers(backend.device, backend.graphic_command_pool, 1, meta.asConstArray(&cmd));

    {
        try backend.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

        const pre_copy_barriers = [_]vk.ImageMemoryBarrier2{
            barrierPreinitializedToTransferSrc(staging_image.handle),
            barrierUndefinedToTransferDst(self.image.handle),
        };

        backend.vkd.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = pre_copy_barriers.len,
            .p_image_memory_barriers = &pre_copy_barriers,
        });

        const image_copy = vk.ImageCopy2{
            .src_offset = std.mem.zeroes(vk.Offset3D),
            .dst_offset = std.mem.zeroes(vk.Offset3D),
            .src_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .base_array_layer = 0,
                .layer_count = 1,
                .mip_level = 0,
            },
            .dst_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .base_array_layer = 0,
                .layer_count = 1,
                .mip_level = 0,
            },
            .extent = .{
                .width = required_extent.width,
                .height = required_extent.height,
                .depth = 1,
            },
        };

        backend.vkd.cmdCopyImage2(cmd, &.{
            .src_image = staging_image.handle,
            .dst_image = self.image.handle,
            .src_image_layout = .transfer_src_optimal,
            .dst_image_layout = .transfer_dst_optimal,
            .region_count = 1,
            .p_regions = meta.asConstArray(&image_copy),
        });

        const sampler_barrier = barrierTransferDstToSampler(self.image.handle);

        backend.vkd.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = meta.asConstArray(&sampler_barrier),
        });

        try backend.vkd.endCommandBuffer(cmd);
    }

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = meta.asConstArray(&cmd),
    };

    const fence = try backend.vkd.createFence(backend.device, &.{}, null);
    defer backend.vkd.destroyFence(backend.device, fence, null);

    try backend.vkd.queueSubmit(backend.graphic_queue, 1, meta.asConstArray(&submit_info), fence);

    self.sampler = try backend.vkd.createSampler(backend.device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = undefined,
        .border_color = vk.BorderColor.int_transparent_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .never,
        .mipmap_mode = .nearest,
        .mip_lod_bias = 0,
        .min_lod = 0,
        .max_lod = 0,
    }, null);

    _ = try backend.vkd.waitForFences(backend.device, 1, meta.asConstArray(&fence), vk.TRUE, 1_000_000_000);

    for (rects.items, paths) |rect, path| {
        try self.map.put(try backend.allocator.dupe(u8, path), rect);
    }

    return self;
}

pub fn deinit(self: *@This(), backend: *VulkanBackend) void {
    backend.vkd.destroySampler(backend.device, self.sampler, null);
    backend.destroyImage(self.image);
    var it = self.map.iterator();
    while (it.next()) |next| self.map.allocator.free(next.key_ptr.*);
    self.map.deinit();
}

pub fn descriptorImageInfo(self: *@This()) vk.DescriptorImageInfo {
    return .{
        .image_layout = .shader_read_only_optimal,
        .image_view = self.image.view,
        .sampler = self.sampler,
    };
}

fn readPngSize(path: []const u8) !vk.Extent2D {
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
        .width = std.mem.readPackedIntForeign(u32, header.width[0..], 0),
        .height = std.mem.readPackedIntForeign(u32, header.height[0..], 0),
    };
}

test "readPngSize" {
    const size = try readPngSize("images/crate_16.png");
    try std.testing.expectEqual(16, size.width);
    try std.testing.expectEqual(16, size.height);
}

fn findFreeRect(extent: vk.Extent2D, existing_rects: []vk.Rect2D, max_extent: vk.Extent2D) ?vk.Rect2D {
    std.debug.assert(std.math.isPowerOfTwo(max_extent.width));
    std.debug.assert(std.math.isPowerOfTwo(max_extent.height));
    std.debug.assert(max_extent.width == max_extent.height);

    const slots = vk.Extent2D{
        .width = max_extent.width / extent.width,
        .height = max_extent.height / extent.height,
    };

    for (0..slots.height) |yo| {
        for (0..slots.width) |xo| {
            const z_orderer = zOrder(.{ @intCast(xo), @intCast(yo) }, slots.width);

            const new_rect = vk.Rect2D{
                .extent = extent,
                .offset = .{
                    .x = @intCast(extent.width * z_orderer[0]),
                    .y = @intCast(extent.height * z_orderer[1]),
                },
            };

            var free = true;

            for (existing_rects) |rect| {
                if (intersection(new_rect, rect)) {
                    free = false;
                    break;
                }
            }

            if (!free) continue;

            return new_rect;
        }
    }

    return null;
}

// Supports  16 bits max
fn zOrder(in: @Vector(2, u32), pitch: u32) @Vector(2, u32) {
    const index = in[1] * pitch + in[0];
    const L: u32 = @bitSizeOf(@TypeOf(index)) / 2;
    var out = @Vector(2, u32){ 0, 0 };

    inline for (0..L) |i| {
        out[0] |= (index & (@as(u32, 1) << (2 * i + 0))) >> (i + 0);
        out[1] |= (index & (@as(u32, 1) << (2 * i + 1))) >> (i + 1);
    }

    return out;
}

fn intersection(a: vk.Rect2D, b: vk.Rect2D) bool {
    {
        var a_min = a.offset.x;
        var a_max = a.offset.x + @as(i32, @intCast(a.extent.width));
        const b_min = b.offset.x;
        const b_max = b.offset.x + @as(i32, @intCast(b.extent.width));

        if (b_min > a_min) a_min = b_min;
        if (b_max < a_max) a_max = b_max;
        if (a_max <= a_min) return false;
    }
    {
        var a_min = a.offset.y;
        var a_max = a.offset.y + @as(i32, @intCast(a.extent.height));
        const b_min = b.offset.y;
        const b_max = b.offset.y + @as(i32, @intCast(b.extent.height));

        if (b_min > a_min) a_min = b_min;
        if (b_max < a_max) a_max = b_max;
        if (a_max <= a_min) return false;
    }
    return true;
}

test "findFreeRect" {
    const extents = [_]vk.Extent2D{
        .{ .width = 16, .height = 16 },
        .{ .width = 32, .height = 32 },
        .{ .width = 16, .height = 16 },
        .{ .width = 32, .height = 32 },
        .{ .width = 64, .height = 64 },
        .{ .width = 32, .height = 32 },
        .{ .width = 32, .height = 32 },
        .{ .width = 16, .height = 16 },
        .{ .width = 16, .height = 16 },
        .{ .width = 64, .height = 64 },
        .{ .width = 32, .height = 32 },
        .{ .width = 32, .height = 32 },
        .{ .width = 32, .height = 32 },
    };

    var rects = std.mem.zeroes([extents.len]vk.Rect2D);

    for (extents, rects[0..], 0..) |extent, *rect, i| {
        rect.* = findFreeRect(extent, rects[0..i], .{ .width = 128, .height = 128 }) orelse unreachable;
    }
}

fn calculateRequiredExtent(rects: []const vk.Rect2D) vk.Extent2D {
    var extent = std.mem.zeroes(vk.Extent2D);

    for (rects) |rect| {
        extent.width = @max(extent.width, rect.extent.width + @as(u32, @intCast(rect.offset.x)));
        extent.height = @max(extent.height, rect.extent.height + @as(u32, @intCast(rect.offset.y)));
    }

    return extent;
}

fn barrierUndefinedToTransferDst(handle: vk.Image) vk.ImageMemoryBarrier2 {
    return vk.ImageMemoryBarrier2{
        .src_stage_mask = .{},
        .src_access_mask = .{},
        .dst_stage_mask = .{},
        .dst_access_mask = .{},
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .image = handle,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };
}

fn barrierPreinitializedToTransferSrc(handle: vk.Image) vk.ImageMemoryBarrier2 {
    return vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_read_bit = true },
        .old_layout = .preinitialized,
        .new_layout = .transfer_src_optimal,
        .image = handle,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };
}

fn barrierTransferDstToSampler(handle: vk.Image) vk.ImageMemoryBarrier2 {
    return vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .image = handle,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };
}
