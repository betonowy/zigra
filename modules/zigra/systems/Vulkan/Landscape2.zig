const std = @import("std");

const tracy = @import("tracy");
const utils = @import("util");
const vk = @import("vk");

const Ctx = @import("Ctx.zig");
const types = @import("Ctx/types.zig");

const Backend = @import("Backend.zig");

const frame_margin = 16;
const frame_width = Backend.frame_target_width + frame_margin * 2;
const frame_height = Backend.frame_target_height + frame_margin * 2;

ctx: *Ctx,

cmd_upload: vk.CommandBuffer,
upload_image: types.ImageData,
device_image: types.ImageData,
sampler: vk.Sampler,

pub fn init(ctx: *Ctx) !@This() {
    const upload_image = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16_uint,
        .initial_layout = .preinitialized,
        .has_view = false,
        .map_memory = true,
        .property = .{ .host_visible_bit = true, .host_coherent_bit = true },
        .tiling = .linear,
        .usage = .{ .transfer_src_bit = true },
    });
    errdefer ctx.destroyImage(upload_image);

    const device_image = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16_uint,
        .property = .{ .device_local_bit = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
    });
    errdefer ctx.destroyImage(device_image);

    const sampler = try ctx.createSampler(.{});
    errdefer ctx.destroySampler(sampler);

    const cmd_upload = try ctx.createCommandBuffer(.secondary);
    errdefer ctx.destroyCommandBuffer(cmd_upload);

    try ctx.beginCommandBuffer(cmd_upload, .{
        .inheritance = &.{ .subpass = 0, .occlusion_query_enable = vk.FALSE },
    });
    {
        const upload_begin_barriers = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{ .copy_bit = true },
                .src_access_mask = .{ .transfer_read_bit = true },
                .dst_stage_mask = .{ .copy_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_src_optimal,
                .image = upload_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            },
            .{
                .src_stage_mask = .{ .fragment_shader_bit = true },
                .src_access_mask = .{ .shader_sampled_read_bit = true },
                .dst_stage_mask = .{ .copy_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .image = device_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            },
        };

        ctx.cmdPipelineBarrier2(cmd_upload, .{
            .image_memory_barriers = &upload_begin_barriers,
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
                .width = frame_width,
                .height = frame_height,
                .depth = 1,
            },
        };

        ctx.vkd.cmdCopyImage2(cmd_upload, &.{
            .src_image = upload_image.handle,
            .dst_image = device_image.handle,
            .src_image_layout = .transfer_src_optimal,
            .dst_image_layout = .transfer_dst_optimal,
            .region_count = 1,
            .p_regions = utils.meta.asConstArray(&image_copy),
        });

        const upload_end_barriers = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{ .copy_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .fragment_shader_bit = true },
                .dst_access_mask = .{ .shader_sampled_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .shader_read_only_optimal,
                .image = device_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            },
        };

        ctx.cmdPipelineBarrier2(cmd_upload, .{
            .image_memory_barriers = &upload_end_barriers,
        });
    }
    try ctx.endCommandBuffer(cmd_upload);

    return .{
        .ctx = ctx,
        .upload_image = upload_image,
        .device_image = device_image,
        .sampler = sampler,
        .cmd_upload = cmd_upload,
    };
}

pub fn getDstSlice(self: *@This()) []u8 {
    return @as([*]u8, @ptrCast(self.upload_image.map.?))[0 .. frame_width * frame_height * @sizeOf(u16)];
}

pub fn cmdUploadData(self: *@This(), cmd_primary: vk.CommandBuffer) !void {
    self.ctx.cmdExecuteCommands(cmd_primary, &.{self.cmd_upload});
}

pub fn deinit(self: *@This()) void {
    self.ctx.destroyCommandBuffer(self.cmd_upload);
    self.ctx.destroySampler(self.sampler);
    self.ctx.destroyImage(self.device_image);
    self.ctx.destroyImage(self.upload_image);
    self.* = undefined;
}
