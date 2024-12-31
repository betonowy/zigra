const std = @import("std");

const zvk = @import("zvk");
const spv = @import("spv");

const Frame = @import("../Frame.zig");
const Ubo = @import("../Ubo.zig");
const Resources = @import("Resources.zig");

device: *zvk.Device,
pipeline: zvk.Pipeline,
set_pool: zvk.DescriptorPool,
set_layout: zvk.DescriptorSetLayout,
layout: zvk.PipelineLayout,

pub fn init(device: *zvk.Device, resources: Resources) !@This() {
    const descriptor_pool = try zvk.DescriptorPool.init(device, .{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 2,
        .n_storage_images = 4,
        .n_uniform_buffers = 1,
    });
    errdefer descriptor_pool.deinit();

    const descriptor_set_layout = try zvk.DescriptorSetLayout.init(device, &.{
        .{
            .binding = 0,
            .stage_flags = .{ .compute_bit = true },
            .type = .uniform_buffer,
        },
        .{
            .binding = 1,
            .stage_flags = .{ .compute_bit = true },
            .type = .storage_image,
        },
        .{
            .binding = 2,
            .stage_flags = .{ .compute_bit = true },
            .type = .storage_image,
        },
        .{
            .binding = 3,
            .stage_flags = .{ .compute_bit = true },
            .type = .storage_image,
        },
        .{
            .binding = 4,
            .stage_flags = .{ .compute_bit = true },
            .type = .storage_image,
        },
    });
    errdefer descriptor_set_layout.deinit();

    const pipeline_layout = try zvk.PipelineLayout.init(device, .{ .dsls = &.{
        descriptor_set_layout,
        resources.set_layout_lm,
        resources.set_layout_lm,
    } });
    errdefer pipeline_layout.deinit();

    const sm = try zvk.ShaderModule.init(device, &spv.render_landscape_comp);
    defer sm.deinit();

    const pipeline = try zvk.Pipeline.initCompute(device, .{
        .layout = pipeline_layout,
        .stage = .{ .module = sm },
    });

    return .{
        .device = device,
        .set_layout = descriptor_set_layout,
        .layout = pipeline_layout,
        .set_pool = descriptor_pool,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: @This()) void {
    self.pipeline.deinit();
    self.layout.deinit();
    self.set_layout.deinit();
    self.set_pool.deinit();
}

pub const FrameResources = struct {
    encoded: zvk.ImageView,
    albedo: zvk.ImageView,
    emission: zvk.ImageView,
    attenuation: zvk.ImageView,
    ubo: Ubo,
};

pub fn createFrameSet(self: @This(), frame: FrameResources) !zvk.DescriptorSet {
    const ds = try zvk.DescriptorSet.init(self.set_pool, self.set_layout);
    errdefer ds.deinit();

    try ds.write(&.{
        frame.ubo.getDescriptorSetWrite(ds, 0),
        frame.encoded.getDescriptorSetWrite(ds, .{
            .binding = 1,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.albedo.getDescriptorSetWrite(ds, .{
            .binding = 2,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.emission.getDescriptorSetWrite(ds, .{
            .binding = 3,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.attenuation.getDescriptorSetWrite(ds, .{
            .binding = 4,
            .layout = .general,
            .type = .storage_image,
        }),
    });

    return ds;
}

pub fn cmdRender(self: @This(), frame: *Frame, resources: Resources) !void {
    frame.cmd.cmdBindPipeline(.compute, self.pipeline);

    try frame.cmd.cmdBindDescriptorSets(.compute, self.layout, .{
        .slice = &.{
            frame.sets.render_landscape,
            resources.set_lm_b,
            resources.set_lm_a,
        },
    }, .{});

    const target_extent = frame.images.render_albedo.options.extent;

    frame.cmd.cmdDispatch(.{
        .target_size = .{ target_extent[0], target_extent[1], 1 },
        .local_size = .{ 16, 16, 1 },
    });

    frame.cmd.cmdPipelineBarrier(.{
        .image = &.{
            frame.images.render_albedo.barrier(.{
                .src_access_mask = .{ .shader_write_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .color_attachment_optimal,
            }),
            frame.images.render_emission.barrier(.{
                .src_access_mask = .{ .shader_write_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
            frame.images.render_attenuation.barrier(.{
                .src_access_mask = .{ .shader_write_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
            resources.image_lm_b.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
            resources.image_lm_a.barrier(.{
                .src_access_mask = .{ .shader_write_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
        },
    });
}
