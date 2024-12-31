const std = @import("std");

const la = @import("la");
const spv = @import("spv");
const zvk = @import("zvk");

const Resources = @import("Resources.zig");

const Frame = @import("../Frame.zig");
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
        .n_storage_images = 2,
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
    });
    errdefer descriptor_set_layout.deinit();

    const pipeline_layout = try zvk.PipelineLayout.init(device, .{ .dsls = &.{
        descriptor_set_layout,
        resources.set_layout_lm,
        resources.set_layout_lm,
    } });
    errdefer pipeline_layout.deinit();

    const sm = try zvk.ShaderModule.init(device, &spv.process_lightmap_comp);
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
    attenuation: zvk.ImageView,
    emission: zvk.ImageView,
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
        frame.emission.getDescriptorSetWrite(ds, .{
            .binding = 1,
            .layout = .general,
            .type = .storage_image,
        }),
        frame.attenuation.getDescriptorSetWrite(ds, .{
            .binding = 2,
            .layout = .general,
            .type = .storage_image,
        }),
    });

    return ds;
}

pub fn cmdRender(self: @This(), frame: *Frame, resources: Resources, extra_loops: usize) !void {
    frame.cmd.cmdBindPipeline(.compute, self.pipeline);

    try self.cmdLoopProcess(frame, .{
        .set_in = resources.set_lm_a,
        .set_out = resources.set_lm_b,
        .image_in = resources.image_lm_a,
        .image_out = resources.image_lm_b,
    });

    for (extra_loops) |_| {
        try self.cmdLoopProcess(frame, .{
            .set_in = resources.set_lm_b,
            .set_out = resources.set_lm_a,
            .image_in = resources.image_lm_b,
            .image_out = resources.image_lm_a,
        });

        try self.cmdLoopProcess(frame, .{
            .set_in = resources.set_lm_a,
            .set_out = resources.set_lm_b,
            .image_in = resources.image_lm_a,
            .image_out = resources.image_lm_b,
        });
    }
}

const LoopProcess = struct {
    set_in: zvk.DescriptorSet,
    set_out: zvk.DescriptorSet,
    image_in: zvk.Image,
    image_out: zvk.Image,
};

fn cmdLoopProcess(self: @This(), frame: *Frame, data: LoopProcess) !void {
    try frame.cmd.cmdBindDescriptorSets(.compute, self.layout, .{
        .slice = &.{
            frame.sets.process_lightmap,
            data.set_in,
            data.set_out,
        },
    }, .{});

    frame.cmd.cmdDispatch(.{
        .target_size = data.image_in.options.extent,
        .local_size = .{ 16, 16, 1 },
    });

    frame.cmd.cmdPipelineBarrier(.{
        .image = &.{
            data.image_in.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
            data.image_out.barrier(.{
                .src_access_mask = .{ .shader_write_bit = true },
                .src_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
        },
    });
}
