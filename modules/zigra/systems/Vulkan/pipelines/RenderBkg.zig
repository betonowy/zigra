const std = @import("std");

const zvk = @import("zvk");
const spv = @import("spv");

const Atlas = @import("../Atlas.zig");
const Frame = @import("../Frame.zig");
const Ubo = @import("../Ubo.zig");

device: *zvk.Device,
pipeline: zvk.Pipeline,
set_pool: zvk.DescriptorPool,
set_layout: zvk.DescriptorSetLayout,
layout: zvk.PipelineLayout,

pub fn init(device: *zvk.Device) !@This() {
    const descriptor_pool = try zvk.DescriptorPool.init(device, .{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 2,
        .n_combined_image_samplers = Atlas.max_layers,
        .n_storage_images = 1,
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
            .type = .combined_image_sampler,
            .count = Atlas.max_layers,
        },
        .{
            .binding = 2,
            .stage_flags = .{ .compute_bit = true },
            .type = .storage_image,
        },
    });
    errdefer descriptor_set_layout.deinit();

    const pipeline_layout = try zvk.PipelineLayout.init(device, .{
        .dsls = &.{descriptor_set_layout},
    });
    errdefer pipeline_layout.deinit();

    const sm = try zvk.ShaderModule.init(device, &spv.render_bkg_comp);
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
    sampler: zvk.Sampler,
    bkg: zvk.ImageView,
    atlas: Atlas,
    ubo: Ubo,
};

pub fn createFrameSet(self: @This(), frame: FrameResources) !zvk.DescriptorSet {
    const ds = try zvk.DescriptorSet.init(self.set_pool, self.set_layout);
    errdefer ds.deinit();

    var ds_writes = std.BoundedArray(zvk.DescriptorSet.Write, 32){};

    ds_writes.appendSliceAssumeCapacity(&.{
        frame.ubo.getDescriptorSetWrite(ds, 0),
        frame.bkg.getDescriptorSetWrite(ds, .{
            .binding = 2,
            .layout = .general,
            .type = .storage_image,
        }),
    });

    try ds_writes.appendSlice(
        (try frame.atlas.getDescriptorSetWrite(ds, frame.sampler, 1)).constSlice(),
    );

    try ds.write(ds_writes.constSlice());

    return ds;
}

pub fn cmdRender(self: @This(), frame: *Frame) !void {
    frame.cmds.gfx_render.cmdBindPipeline(.compute, self.pipeline);

    try frame.cmds.gfx_render.cmdBindDescriptorSets(.compute, self.layout, .{
        .slice = &.{frame.sets.render_bkg},
    }, .{});

    const target_extent = frame.images.render_bkg.options.extent;

    frame.cmds.gfx_render.cmdDispatch(.{
        .target_size = .{ target_extent[0], target_extent[1], 1 },
        .local_size = .{ 16, 16, 1 },
    });

    frame.cmds.gfx_render.cmdPipelineBarrier(.{ .memory = &.{.{
        .src_stage_mask = .{ .compute_shader_bit = true },
        .dst_stage_mask = .{ .compute_shader_bit = true },
    }} });
}
