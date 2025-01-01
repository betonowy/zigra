const std = @import("std");

const zvk = @import("zvk");
const spv = @import("spv");

const Frame = @import("../Frame.zig");
const Resources = @import("Resources.zig");
const Ubo = @import("../Ubo.zig");

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

    const pipeline_layout = try zvk.PipelineLayout.init(device, .{
        .dsls = &.{
            descriptor_set_layout,
            resources.set_layout_lm,
        },
    });
    errdefer pipeline_layout.deinit();

    const sm = try zvk.ShaderModule.init(device, &spv.compose_intermediate_comp);
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
    render_landscape_albedo: zvk.ImageView,
    render_world_albedo: zvk.ImageView,
    render_bkg: zvk.ImageView,
    im: zvk.ImageView,
    ubo: Ubo,
};

pub fn createFrameSet(self: @This(), frame: FrameResources) !zvk.DescriptorSet {
    const ds = try zvk.DescriptorSet.init(
        self.set_pool,
        self.set_layout,
    );
    errdefer ds.deinit();

    try ds.write(&.{
        frame.ubo.getDescriptorSetWrite(ds, 0),
        frame.im.getDescriptorSetWrite(ds, .{
            .binding = 1,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.render_bkg.getDescriptorSetWrite(ds, .{
            .binding = 2,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.render_landscape_albedo.getDescriptorSetWrite(ds, .{
            .binding = 3,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.render_world_albedo.getDescriptorSetWrite(ds, .{
            .binding = 4,
            .layout = .general,
            .type = .storage_image,
        }),
    });

    return ds;
}

pub fn cmdRender(self: @This(), frame: *Frame, resources: Resources) !void {
    frame.cmds.gfx_present.cmdBindPipeline(.compute, self.pipeline);

    try frame.cmds.gfx_present.cmdBindDescriptorSets(.compute, self.layout, .{
        .slice = &.{
            frame.sets.compose_intermediate,
            resources.set_lm_b,
        },
    }, .{});

    const target_extent = frame.images.render_bkg.options.extent;

    frame.cmds.gfx_present.cmdDispatch(.{
        .target_size = .{ target_extent[0], target_extent[1], 1 },
        .local_size = .{ 16, 16, 1 },
    });

    frame.cmds.gfx_present.cmdPipelineBarrier(.{
        .image = &.{
            frame.images.ldr_im.barrier(.{
                .src_access_mask = .{ .shader_write_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .fragment_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .shader_read_only_optimal,
                .src_queue = self.device.queue_graphics,
                .dst_queue = self.device.queue_graphics,
            }),
        },
    });
}
