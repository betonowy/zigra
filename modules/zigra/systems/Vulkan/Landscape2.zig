const std = @import("std");

const tracy = @import("tracy");
const utils = @import("util");
const vk = @import("vk");

const Ctx = @import("Ctx.zig");
const types = @import("Ctx/types.zig");
const spv = @import("spv");
const builder = @import("Ctx/builder.zig");

const Backend = @import("Backend.zig");

const frame_margin = 64;
const frame_width = Backend.frame_target_width + frame_margin * 2;
const frame_height = Backend.frame_target_height + frame_margin * 2;

const comp_local_group_size = @Vector(2, u32){ 16, 16 };

const comp_workgroups_size = @Vector(2, u32){
    (frame_width - 1) / comp_local_group_size[0] + 1,
    (frame_height - 1) / comp_local_group_size[1] + 1,
};

const spread_iteration_count = 5;

comptime {
    // This provides an ability to have deterministic source/dest
    // for interpolating old spread values over the new frame when
    // accounting for camera position difference between frames.
    std.debug.assert(spread_iteration_count % 2 == 1);
}

ctx: *Ctx,

cmd_process_p1: vk.CommandBuffer,
cmd_process_p2: vk.CommandBuffer,

upload_image: types.ImageData,
device_image: types.ImageData,
albedo_image: types.ImageData,
src_light_image: types.ImageData,
spread_light_image: [2]types.ImageData,
processed_image: types.ImageData,
processed_image_sampler: vk.Sampler,

dsl_setup: vk.DescriptorSetLayout,
ds_setup: vk.DescriptorSet,
pip_setup: vk.Pipeline,
pipl_setup: vk.PipelineLayout,

dsl_spread: vk.DescriptorSetLayout,
ds_spread: [2]vk.DescriptorSet,
pip_spread: vk.Pipeline,
pipl_spread: vk.PipelineLayout,

dsl_assemble: vk.DescriptorSetLayout,
ds_assemble: vk.DescriptorSet,
pip_assemble: vk.Pipeline,
pipl_assemble: vk.PipelineLayout,

pub fn init(ctx: *Ctx) !@This() {
    const upload_image = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16_uint,
        .initial_layout = .undefined,
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
        .usage = .{ .transfer_dst_bit = true, .storage_bit = true },
    });
    errdefer ctx.destroyImage(device_image);

    const albedo_image = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16g16b16a16_sfloat,
        .property = .{ .device_local_bit = true },
        .tiling = .optimal,
        .usage = .{ .storage_bit = true },
    });
    errdefer ctx.destroyImage(albedo_image);

    const src_light_image = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16g16b16a16_sfloat,
        .property = .{ .device_local_bit = true },
        .tiling = .optimal,
        .usage = .{ .storage_bit = true },
    });
    errdefer ctx.destroyImage(src_light_image);

    const spread_light_image_0 = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16g16b16a16_sfloat,
        .property = .{ .device_local_bit = true },
        .tiling = .optimal,
        .usage = .{ .storage_bit = true },
    });
    errdefer ctx.destroyImage(spread_light_image_0);

    const spread_light_image_1 = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16g16b16a16_sfloat,
        .property = .{ .device_local_bit = true },
        .tiling = .optimal,
        .usage = .{ .storage_bit = true },
    });
    errdefer ctx.destroyImage(spread_light_image_1);

    const processed_image = try ctx.createImage(.{
        .aspect_mask = .{ .color_bit = true },
        .extent = .{ .width = frame_width, .height = frame_height },
        .format = .r16g16b16a16_sfloat,
        .property = .{ .device_local_bit = true },
        .tiling = .optimal,
        .usage = .{ .storage_bit = true, .sampled_bit = true },
    });
    errdefer ctx.destroyImage(processed_image);

    const processed_image_sampler = try ctx.createSampler(.{});
    errdefer ctx.destroySampler(processed_image_sampler);

    const dsl_setup = try ctx.createDescriptorSetLayout(&.{
        .{
            .binding = 0, // device_image
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 1, // albedo_image
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 2, // src_light_image
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 3, // spread_light_image[0]
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 4, // spread_light_image[1]
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
    });
    errdefer ctx.destroyDescriptorSetLayout(dsl_setup);

    const ds_setup = try ctx.allocateDescriptorSet(dsl_setup);
    errdefer ctx.freeDescriptorSet(ds_setup);
    {
        const ds_setup_device_image = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 0,
            .dst_set = ds_setup,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = device_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_setup_albedo_image = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = ds_setup,
            .p_image_info = &.{vk.DescriptorImageInfo{
                .image_layout = .general,
                .image_view = albedo_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_setup_src_light_image = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 2,
            .dst_set = ds_setup,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = src_light_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_setup_spread_light_image_0 = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 3,
            .dst_set = ds_setup,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = spread_light_image_0.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_setup_spread_light_image_1 = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 4,
            .dst_set = ds_setup,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = spread_light_image_1.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const writes = [_]vk.WriteDescriptorSet{
            ds_setup_device_image,
            ds_setup_albedo_image,
            ds_setup_src_light_image,
            ds_setup_spread_light_image_0,
            ds_setup_spread_light_image_1,
        };

        ctx.vkd.updateDescriptorSets(ctx.device, writes.len, &writes, 0, null);
    }

    const pipl_setup = try ctx.createPipelineLayout(.{ .dsl = dsl_setup, .pcr = &.{
        builder.pipeline.pushConstantComp(@sizeOf(types.CameraPosDiffPushConstant)),
    } });
    errdefer ctx.destroyPipelineLayout(pipl_setup);

    const sm_comp_setup = try ctx.createShaderModule(&spv.landscape2_setup_comp);
    defer ctx.destroyShaderModule(sm_comp_setup);

    const pip_setup = try ctx.createComputePipeline(.{
        .layout = pipl_setup,
        .stage = builder.pipeline.shader_stage.comp(sm_comp_setup, .{}),
    });
    errdefer ctx.destroyPipeline(pip_setup);

    const dsl_spread = try ctx.createDescriptorSetLayout(&.{
        .{
            .binding = 0, // src
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 1, // baseline
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 2, // dst
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
    });
    errdefer ctx.destroyDescriptorSetLayout(dsl_spread);

    const ds_spread_0_to_1 = try ctx.allocateDescriptorSet(dsl_spread);
    errdefer ctx.freeDescriptorSet(ds_spread_0_to_1);
    const ds_spread_1_to_0 = try ctx.allocateDescriptorSet(dsl_spread);
    errdefer ctx.freeDescriptorSet(ds_spread_1_to_0);
    {
        const ds_spread_0_to_1_src = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 0,
            .dst_set = ds_spread_0_to_1,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = spread_light_image_0.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_spread_0_to_1_baseline = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = ds_spread_0_to_1,
            .p_image_info = &.{vk.DescriptorImageInfo{
                .image_layout = .general,
                .image_view = src_light_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_spread_0_to_1_dst = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 2,
            .dst_set = ds_spread_0_to_1,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = spread_light_image_1.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_spread_1_to_0_src = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 0,
            .dst_set = ds_spread_1_to_0,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = spread_light_image_1.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_spread_1_to_0_baseline = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = ds_spread_1_to_0,
            .p_image_info = &.{vk.DescriptorImageInfo{
                .image_layout = .general,
                .image_view = src_light_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_spread_1_to_0_dst = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 2,
            .dst_set = ds_spread_1_to_0,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = spread_light_image_0.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const writes = [_]vk.WriteDescriptorSet{
            ds_spread_0_to_1_src,
            ds_spread_0_to_1_baseline,
            ds_spread_0_to_1_dst,
            ds_spread_1_to_0_src,
            ds_spread_1_to_0_baseline,
            ds_spread_1_to_0_dst,
        };

        ctx.vkd.updateDescriptorSets(ctx.device, writes.len, &writes, 0, null);
    }

    const pipl_spread = try ctx.createPipelineLayout(.{ .dsl = dsl_spread });
    errdefer ctx.destroyPipelineLayout(pipl_spread);

    const sm_comp_spread = try ctx.createShaderModule(&spv.landscape2_spread_comp);
    defer ctx.destroyShaderModule(sm_comp_spread);

    const pip_spread = try ctx.createComputePipeline(.{
        .layout = pipl_spread,
        .stage = builder.pipeline.shader_stage.comp(sm_comp_spread, .{}),
    });
    errdefer ctx.destroyPipeline(pip_spread);

    const cmd_process_p1 = try ctx.createCommandBuffer(.secondary);
    errdefer ctx.destroyCommandBuffer(cmd_process_p1);
    const cmd_process_p2 = try ctx.createCommandBuffer(.secondary);
    errdefer ctx.destroyCommandBuffer(cmd_process_p2);

    try ctx.beginCommandBuffer(cmd_process_p1, .{
        .inheritance = &.{ .subpass = 0, .occlusion_query_enable = vk.FALSE },
    });

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
            .src_stage_mask = .{ .compute_shader_bit = true },
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

    ctx.cmdPipelineBarrier2(cmd_process_p1, .{
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

    ctx.vkd.cmdCopyImage2(cmd_process_p1, &.{
        .src_image = upload_image.handle,
        .dst_image = device_image.handle,
        .src_image_layout = .transfer_src_optimal,
        .dst_image_layout = .transfer_dst_optimal,
        .region_count = 1,
        .p_regions = utils.meta.asConstArray(&image_copy),
    });

    {
        const copy_barriers = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{ .copy_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .general,
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
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = albedo_image.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = src_light_image.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = spread_light_image_0.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = spread_light_image_1.handle,
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

        ctx.cmdPipelineBarrier2(cmd_process_p1, .{ .image_memory_barriers = &copy_barriers });
    }
    try ctx.endCommandBuffer(cmd_process_p1);
    try ctx.beginCommandBuffer(cmd_process_p2, .{
        .inheritance = &.{ .subpass = 0, .occlusion_query_enable = vk.FALSE },
    });
    {
        const decode_to_spread_barriers = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .image = src_light_image.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .image = spread_light_image_0.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = spread_light_image_1.handle,
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

        ctx.cmdPipelineBarrier2(cmd_process_p2, .{ .image_memory_barriers = &decode_to_spread_barriers });
    }
    var loop_variant: enum { spread_0_to_1, spread_1_to_0 } = .spread_0_to_1;
    {
        ctx.cmdBindPipeline(cmd_process_p2, .compute, pip_spread);

        for (0..spread_iteration_count) |_| {
            const ds_current = switch (loop_variant) {
                .spread_0_to_1 => ds_spread_0_to_1,
                .spread_1_to_0 => ds_spread_1_to_0,
            };

            ctx.cmdBindDescriptorSets(cmd_process_p2, .compute, pipl_spread, .{ .slice = &.{ds_current} }, .{});
            ctx.cmdDispatch(cmd_process_p2, .{ comp_workgroups_size[0], comp_workgroups_size[1], 1 });

            const img_spread: struct {
                src: types.ImageData,
                dst: types.ImageData,
            } = switch (loop_variant) {
                .spread_0_to_1 => .{ .src = spread_light_image_0, .dst = spread_light_image_1 },
                .spread_1_to_0 => .{ .src = spread_light_image_0, .dst = spread_light_image_1 },
            };

            const spread_finish_barriers = [_]vk.ImageMemoryBarrier2{
                .{
                    .src_stage_mask = .{ .compute_shader_bit = true },
                    .src_access_mask = .{ .shader_read_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .shader_write_bit = true },
                    .old_layout = .general,
                    .new_layout = .general,
                    .image = img_spread.src.handle,
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
                    .src_stage_mask = .{ .compute_shader_bit = true },
                    .src_access_mask = .{ .shader_write_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .shader_read_bit = true },
                    .old_layout = .general,
                    .new_layout = .general,
                    .image = img_spread.dst.handle,
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

            ctx.cmdPipelineBarrier2(cmd_process_p2, .{ .image_memory_barriers = &spread_finish_barriers });

            loop_variant = switch (loop_variant) {
                .spread_0_to_1 => .spread_1_to_0,
                .spread_1_to_0 => .spread_0_to_1,
            };
        }
    }
    const dsl_assemble = try ctx.createDescriptorSetLayout(&.{
        .{
            .binding = 0, // albedo
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 1, // light
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
        .{
            .binding = 2, // out
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .compute_bit = true },
        },
    });
    errdefer ctx.destroyDescriptorSetLayout(dsl_assemble);

    const ds_assemble = try ctx.allocateDescriptorSet(dsl_assemble);
    errdefer ctx.freeDescriptorSet(ds_assemble);
    {
        const ds_assemble_albedo = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 0,
            .dst_set = ds_assemble,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = albedo_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_assemble_light = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = ds_assemble,
            .p_image_info = &.{vk.DescriptorImageInfo{
                .image_layout = .general,
                .image_view = switch (loop_variant) {
                    .spread_0_to_1 => spread_light_image_0.view,
                    .spread_1_to_0 => spread_light_image_1.view,
                },
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const ds_assemble_out = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .dst_array_element = 0,
            .dst_binding = 2,
            .dst_set = ds_assemble,
            .p_image_info = &.{.{
                .image_layout = .general,
                .image_view = processed_image.view,
                .sampler = undefined,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const writes = [_]vk.WriteDescriptorSet{
            ds_assemble_albedo,
            ds_assemble_light,
            ds_assemble_out,
        };

        ctx.vkd.updateDescriptorSets(ctx.device, writes.len, &writes, 0, null);
    }

    const pipl_assemble = try ctx.createPipelineLayout(.{ .dsl = dsl_assemble });
    errdefer ctx.destroyPipelineLayout(pipl_assemble);

    const sm_comp_assemble = try ctx.createShaderModule(&spv.landscape2_assemble_comp);
    defer ctx.destroyShaderModule(sm_comp_assemble);

    const pip_assemble = try ctx.createComputePipeline(.{
        .layout = pipl_assemble,
        .stage = builder.pipeline.shader_stage.comp(sm_comp_assemble, .{}),
    });
    errdefer ctx.destroyPipeline(pip_assemble);
    {
        const spread_to_assemble_barriers = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = processed_image.handle,
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

        ctx.cmdPipelineBarrier2(cmd_process_p2, .{ .image_memory_barriers = &spread_to_assemble_barriers });
    }
    {
        ctx.cmdBindPipeline(cmd_process_p2, .compute, pip_assemble);
        ctx.cmdBindDescriptorSets(cmd_process_p2, .compute, pipl_assemble, .{ .slice = &.{ds_assemble} }, .{});
        ctx.cmdDispatch(cmd_process_p2, .{ comp_workgroups_size[0], comp_workgroups_size[1], 1 });
    }
    {
        const pipeline_finish_barriers = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{ .copy_bit = true },
                .src_access_mask = .{ .memory_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .memory_write_bit = true },
                .old_layout = .general,
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
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .image = albedo_image.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .memory_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .memory_write_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .image = src_light_image.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .image = spread_light_image_0.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .image = spread_light_image_1.handle,
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
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .old_layout = .general,
                .new_layout = .shader_read_only_optimal,
                .image = processed_image.handle,
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

        ctx.cmdPipelineBarrier2(cmd_process_p2, .{ .image_memory_barriers = &pipeline_finish_barriers });
    }

    try ctx.endCommandBuffer(cmd_process_p2);

    return .{
        .ctx = ctx,
        .upload_image = upload_image,
        .device_image = device_image,
        .albedo_image = albedo_image,
        .src_light_image = src_light_image,
        .spread_light_image = .{ spread_light_image_0, spread_light_image_1 },
        .processed_image = processed_image,
        .processed_image_sampler = processed_image_sampler,
        .ds_setup = ds_setup,
        .dsl_setup = dsl_setup,
        .pipl_setup = pipl_setup,
        .pip_setup = pip_setup,
        .ds_spread = .{ ds_spread_0_to_1, ds_spread_1_to_0 },
        .dsl_spread = dsl_spread,
        .pipl_spread = pipl_spread,
        .pip_spread = pip_spread,
        .dsl_assemble = dsl_assemble,
        .ds_assemble = ds_assemble,
        .pipl_assemble = pipl_assemble,
        .pip_assemble = pip_assemble,
        .cmd_process_p1 = cmd_process_p1,
        .cmd_process_p2 = cmd_process_p2,
    };
}

pub fn getDstExtent(_: @This()) @Vector(2, u32) {
    return .{ frame_width, frame_height };
}

pub fn getDstSlice(self: *@This()) []u8 {
    return @as([*]u8, @ptrCast(self.upload_image.map.?))[0 .. frame_width * frame_height * @sizeOf(u16)];
}

pub fn cmdUploadData(self: *@This(), cmd_primary: vk.CommandBuffer, camera_pos_diff: @Vector(2, i32)) !void {
    const push_constant = types.CameraPosDiffPushConstant{ .camera_pos_diff = camera_pos_diff };
    self.ctx.cmdExecuteCommands(cmd_primary, &.{self.cmd_process_p1});
    self.ctx.cmdBindPipeline(cmd_primary, .compute, self.pip_setup);
    self.ctx.cmdBindDescriptorSets(cmd_primary, .compute, self.pipl_setup, .{ .slice = &.{self.ds_setup} }, .{});
    self.ctx.cmdPushConstants(cmd_primary, self.pipl_setup, .{ .compute_bit = true }, push_constant);
    self.ctx.cmdDispatch(cmd_primary, .{ comp_workgroups_size[0], comp_workgroups_size[1], 1 });
    self.ctx.cmdExecuteCommands(cmd_primary, &.{self.cmd_process_p2});
}

pub fn deinit(self: *@This()) void {
    self.ctx.destroyCommandBuffer(self.cmd_process_p2);
    self.ctx.destroyCommandBuffer(self.cmd_process_p1);
    self.ctx.destroyPipeline(self.pip_assemble);
    self.ctx.destroyPipeline(self.pip_spread);
    self.ctx.destroyPipeline(self.pip_setup);
    self.ctx.destroyPipelineLayout(self.pipl_assemble);
    self.ctx.destroyPipelineLayout(self.pipl_spread);
    self.ctx.destroyPipelineLayout(self.pipl_setup);
    self.ctx.freeDescriptorSet(self.ds_assemble);
    self.ctx.freeDescriptorSet(self.ds_spread[1]);
    self.ctx.freeDescriptorSet(self.ds_spread[0]);
    self.ctx.freeDescriptorSet(self.ds_setup);
    self.ctx.destroyDescriptorSetLayout(self.dsl_assemble);
    self.ctx.destroyDescriptorSetLayout(self.dsl_spread);
    self.ctx.destroyDescriptorSetLayout(self.dsl_setup);
    self.ctx.destroySampler(self.processed_image_sampler);
    self.ctx.destroyImage(self.processed_image);
    self.ctx.destroyImage(self.spread_light_image[1]);
    self.ctx.destroyImage(self.spread_light_image[0]);
    self.ctx.destroyImage(self.src_light_image);
    self.ctx.destroyImage(self.albedo_image);
    self.ctx.destroyImage(self.device_image);
    self.ctx.destroyImage(self.upload_image);
    self.* = undefined;
}
