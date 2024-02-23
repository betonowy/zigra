const std = @import("std");
const vk = @import("vk.zig");
const types = @import("vulkan_types.zig");
const Backend = @import("VulkanBackend.zig");
const meta = @import("meta.zig");
const stb = @cImport(@cInclude("stb/stb_image.h"));

pub const image_size = 128;
const tiles_width_count = Backend.frame_target_width / image_size + 2;
const tiles_height_count = Backend.frame_target_heigth / image_size + 2;
pub const tile_count = tiles_width_count * tiles_height_count;

const Tile = struct {
    upload_image: types.ImageData,
    device_image: types.ImageData,
    coord: @Vector(2, i16),
    sampler: vk.Sampler,
    used_flag: bool,
    table_index: u32,
};

const ActiveSet = struct {
    tile: *Tile,
    is_reused: bool,
};

const UploadSet = struct {
    tile: *Tile,
    data: []const u8,
};

pub const ActiveSets = std.BoundedArray(ActiveSet, tile_count);
pub const UploadSets = std.BoundedArray(UploadSet, tile_count);

tiles: [tile_count]Tile,
active_sets: ActiveSets,

pub fn init(backend: *Backend) !@This() {
    var self = @This(){
        .tiles = std.mem.zeroes([tile_count]Tile),
        .active_sets = undefined,
    };

    errdefer self.deinit(backend);

    for (self.tiles[0..], 0..) |*tile, i| {
        tile.coord = .{ std.math.maxInt(i16), std.math.maxInt(i16) };
        tile.table_index = @intCast(i);

        tile.upload_image = try backend.createImage(.{
            .aspect_mask = .{ .color_bit = true },
            .extent = .{ .width = image_size, .height = image_size },
            .format = .r8_uint,
            .initial_layout = .preinitialized,
            .has_view = false,
            .map_memory = true,
            .property = .{ .host_visible_bit = true, .host_coherent_bit = true },
            .tiling = .linear,
            .usage = .{ .transfer_src_bit = true },
        });

        tile.device_image = try backend.createImage(.{
            .aspect_mask = .{ .color_bit = true },
            .extent = .{ .width = image_size, .height = image_size },
            .format = .r8_uint,
            .property = .{ .device_local_bit = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        });

        tile.sampler = try backend.vkd.createSampler(backend.device, &.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
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
    }

    return self;
}

pub fn deinit(self: *@This(), backend: *Backend) void {
    for (self.tiles[0..]) |*tile| {
        if (tile.sampler != .null_handle) backend.vkd.destroySampler(backend.device, tile.sampler, null);
        if (tile.upload_image.handle != .null_handle) backend.destroyImage(tile.upload_image);
        if (tile.device_image.handle != .null_handle) backend.destroyImage(tile.device_image);
    }
}

pub fn recordUploadData(self: *@This(), backend: *Backend, cmd: vk.CommandBuffer, upload_sets: UploadSets) !void {
    _ = self; // autofix
    for (upload_sets.constSlice()) |set| {
        const dst: [*]u8 = @ptrCast(set.tile.upload_image.map.?);
        @memcpy(dst, set.data);
    }

    for (upload_sets.constSlice()) |set| {
        const begin_barriers = [_]vk.ImageMemoryBarrier2{
            barrierUndefinedToTransferSrc(set.tile.upload_image.handle),
            barrierUndefinedToTransferDst(set.tile.device_image.handle),
        };

        backend.vkd.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = begin_barriers.len,
            .p_image_memory_barriers = &begin_barriers,
        });
    }

    for (upload_sets.constSlice()) |set| {
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
                .width = image_size,
                .height = image_size,
                .depth = 1,
            },
        };

        backend.vkd.cmdCopyImage2(cmd, &.{
            .src_image = set.tile.upload_image.handle,
            .dst_image = set.tile.device_image.handle,
            .src_image_layout = .transfer_src_optimal,
            .dst_image_layout = .transfer_dst_optimal,
            .region_count = 1,
            .p_regions = meta.asConstArray(&image_copy),
        });
    }

    for (upload_sets.constSlice()) |set| {
        const finish_barriers = [_]vk.ImageMemoryBarrier2{
            barrierTransferDstToSampler(set.tile.device_image.handle),
        };

        backend.vkd.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = finish_barriers.len,
            .p_image_memory_barriers = &finish_barriers,
        });
    }
}

fn barrierUndefinedToTransferDst(handle: vk.Image) vk.ImageMemoryBarrier2 {
    return vk.ImageMemoryBarrier2{
        .src_stage_mask = .{},
        .src_access_mask = .{},
        .dst_stage_mask = .{ .copy_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
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

fn barrierUndefinedToTransferSrc(handle: vk.Image) vk.ImageMemoryBarrier2 {
    return vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .copy_bit = true },
        .src_access_mask = .{ .transfer_read_bit = true },
        .dst_stage_mask = .{ .copy_bit = true },
        .dst_access_mask = .{ .transfer_read_bit = true },
        .old_layout = .undefined,
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
        .src_stage_mask = .{ .copy_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_sampled_read_bit = true },
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

pub fn recalculateActiveSets(self: *@This(), target: @Vector(2, i16)) !void {
    const tile_size = @as(@Vector(2, i16), @splat(image_size));

    const extent: @Vector(2, i16) = .{ Backend.frame_target_width, Backend.frame_target_heigth };
    const offset = target - extent / @as(@Vector(2, i16), @splat(2));

    const start_pos = @divFloor(offset, tile_size) * tile_size;
    const limit = offset + extent;
    var current = start_pos;
    var row: i16 = 0;

    var positions = std.BoundedArray(@Vector(2, i16), tile_count).init(0) catch unreachable;

    while (current[1] < limit[1]) {
        try positions.append(current);

        if (current[0] + tile_size[0] >= limit[0]) {
            row += 1;
            current[0] = start_pos[0];
            current[1] = start_pos[1] + row * tile_size[1];
        } else {
            current[0] += tile_size[0];
        }
    }

    self.active_sets.resize(0) catch unreachable;

    // Reuse tiles that might contain valid data
    for (self.tiles[0..]) |*tile| {
        tile.used_flag = false;

        for (positions.constSlice(), 0..) |position, i| {
            if (@reduce(.Or, position != tile.coord)) continue;

            tile.used_flag = true;
            _ = positions.swapRemove(i);

            try self.active_sets.append(.{
                .tile = tile,
                .is_reused = true,
            });
            break;
        }
    }

    // For the rest grab unused tiles to fill the set
    for (positions.constSlice()) |position| {
        for (self.tiles[0..]) |*tile| {
            if (tile.used_flag) continue;

            tile.coord = position;
            tile.used_flag = true;

            try self.active_sets.append(.{
                .tile = tile,
                .is_reused = false,
            });
            break;
        }
    }
}

test "recalculateActiveSets" {
    var self = @This(){
        .tiles = std.mem.zeroes([tile_count]Tile),
        .active_sets = undefined,
    };

    try self.recalculateActiveSets(.{ -324, -546 });
    {
        const sets = self.active_sets.slice();
        try std.testing.expectEqual(sets.len, 9);
        try std.testing.expectEqual(.{ -512, -768 }, sets[0].tile.coord);
        try std.testing.expectEqual(.{ -384, -768 }, sets[1].tile.coord);
        try std.testing.expectEqual(.{ -256, -768 }, sets[2].tile.coord);
        try std.testing.expectEqual(.{ -512, -640 }, sets[3].tile.coord);
        try std.testing.expectEqual(.{ -384, -640 }, sets[4].tile.coord);
        try std.testing.expectEqual(.{ -256, -640 }, sets[5].tile.coord);
        try std.testing.expectEqual(.{ -512, -512 }, sets[6].tile.coord);
        try std.testing.expectEqual(.{ -384, -512 }, sets[7].tile.coord);
        try std.testing.expectEqual(.{ -256, -512 }, sets[8].tile.coord);
        try std.testing.expect(!sets[0].is_reused);
        try std.testing.expect(!sets[1].is_reused);
        try std.testing.expect(!sets[2].is_reused);
        try std.testing.expect(!sets[3].is_reused);
        try std.testing.expect(!sets[4].is_reused);
        try std.testing.expect(!sets[5].is_reused);
        try std.testing.expect(!sets[6].is_reused);
        try std.testing.expect(!sets[7].is_reused);
        try std.testing.expect(!sets[8].is_reused);
    }
    try self.recalculateActiveSets(.{ -324, -546 });
    {
        const sets = self.active_sets.slice();
        try std.testing.expectEqual(sets.len, 9);
        try std.testing.expectEqual(.{ -512, -768 }, sets[0].tile.coord);
        try std.testing.expectEqual(.{ -384, -768 }, sets[1].tile.coord);
        try std.testing.expectEqual(.{ -256, -768 }, sets[2].tile.coord);
        try std.testing.expectEqual(.{ -512, -640 }, sets[3].tile.coord);
        try std.testing.expectEqual(.{ -384, -640 }, sets[4].tile.coord);
        try std.testing.expectEqual(.{ -256, -640 }, sets[5].tile.coord);
        try std.testing.expectEqual(.{ -512, -512 }, sets[6].tile.coord);
        try std.testing.expectEqual(.{ -384, -512 }, sets[7].tile.coord);
        try std.testing.expectEqual(.{ -256, -512 }, sets[8].tile.coord);
        try std.testing.expect(sets[0].is_reused);
        try std.testing.expect(sets[1].is_reused);
        try std.testing.expect(sets[2].is_reused);
        try std.testing.expect(sets[3].is_reused);
        try std.testing.expect(sets[4].is_reused);
        try std.testing.expect(sets[5].is_reused);
        try std.testing.expect(sets[6].is_reused);
        try std.testing.expect(sets[7].is_reused);
        try std.testing.expect(sets[8].is_reused);
    }
    try self.recalculateActiveSets(.{ -416, -356 });
    {
        const sets = self.active_sets.slice();
        try std.testing.expectEqual(sets.len, 6);
        try std.testing.expectEqual(.{ -512, -512 }, sets[0].tile.coord);
        try std.testing.expectEqual(.{ -384, -512 }, sets[1].tile.coord);
        try std.testing.expectEqual(.{ -640, -512 }, sets[2].tile.coord);
        try std.testing.expectEqual(.{ -384, -384 }, sets[3].tile.coord);
        try std.testing.expectEqual(.{ -512, -384 }, sets[4].tile.coord);
        try std.testing.expectEqual(.{ -640, -384 }, sets[5].tile.coord);
        try std.testing.expect(sets[0].is_reused);
        try std.testing.expect(sets[1].is_reused);
        try std.testing.expect(!sets[2].is_reused);
        try std.testing.expect(!sets[3].is_reused);
        try std.testing.expect(!sets[4].is_reused);
        try std.testing.expect(!sets[5].is_reused);
    }
}
