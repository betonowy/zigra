const std = @import("std");

const zvk = @import("zvk");
const spv = @import("spv");

const Frame = @import("../Frame.zig");
const Ubo = @import("../Ubo.zig");

device: *zvk.Device,
pipeline: zvk.Pipeline,
set_pool: zvk.DescriptorPool,
set_layout: zvk.DescriptorSetLayout,
layout: zvk.PipelineLayout,

pub fn init(device: *zvk.Device, swapchain: zvk.Swapchain) !@This() {
    const descriptor_pool = try zvk.DescriptorPool.init(device, .{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 2,
        .n_combined_image_samplers = 1,
        .n_uniform_buffers = 1,
    });
    errdefer descriptor_pool.deinit();

    const descriptor_set_layout = try zvk.DescriptorSetLayout.init(device, &.{
        .{
            .binding = 0,
            .stage_flags = .{ .fragment_bit = true },
            .type = .uniform_buffer,
        },
        .{
            .binding = 1,
            .stage_flags = .{ .fragment_bit = true },
            .type = .combined_image_sampler,
        },
        .{
            .binding = 2,
            .stage_flags = .{ .fragment_bit = true },
            .type = .combined_image_sampler,
        },
    });
    errdefer descriptor_set_layout.deinit();

    const pipeline_layout = try zvk.PipelineLayout.init(device, .{
        .dsls = &.{descriptor_set_layout},
    });
    errdefer pipeline_layout.deinit();

    const sm_vs = try zvk.ShaderModule.init(device, &spv.compose_present_vert);
    defer sm_vs.deinit();

    const sm_fs = try zvk.ShaderModule.init(device, &spv.compose_present_frag);
    defer sm_fs.deinit();

    const pipeline = try zvk.Pipeline.initGraphics(device, .{
        .stages = &.{
            .{ .module = sm_vs.handle, .p_name = "main", .stage = .{ .vertex_bit = true } },
            .{ .module = sm_fs.handle, .p_name = "main", .stage = .{ .fragment_bit = true } },
        },
        .topology = .triangle_list,
        .rasterization = .{ .front_face = .clockwise, .polygon_mode = .fill },
        .depth_stencil = .{},
        .color_blend = .{ .attachments = &.{.{}} },
        .dynamic_states = &.{ .viewport, .scissor },
        .layout = pipeline_layout,
        .target_info = .{ .color_attachments = &.{swapchain.format} },
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
    dui: zvk.ImageView,
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
            .type = .combined_image_sampler,
            .sampler = frame.sampler,
        }),
        frame.dui.getDescriptorSetWrite(ds, .{
            .binding = 2,
            .layout = .shader_read_only_optimal,
            .type = .combined_image_sampler,
            .sampler = frame.sampler,
        }),
    });

    return ds;
}

pub fn cmdRender(self: @This(), frame: *Frame, swapchain: zvk.Swapchain, image_index: u32) !void {
    try frame.cmd.cmdBeginRendering(.{
        .render_area = .{ .offset = .{ 0, 0 }, .extent = swapchain.extent },
        .color_attachments = &.{.{
            .view = .{ .handle = swapchain.views[image_index], .device = undefined },
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
            .layout = .color_attachment_optimal,
        }},
    });

    frame.cmd.cmdBindPipeline(.graphics, self.pipeline);

    try frame.cmd.cmdBindDescriptorSets(.graphics, self.layout, .{
        .slice = &.{frame.sets.compose_present},
    }, .{});

    try frame.cmd.cmdScissor(&.{.{ .size = swapchain.extent }});
    try frame.cmd.cmdViewport(&.{.{ .size = @floatFromInt(swapchain.extent) }});
    frame.cmd.cmdDraw(.{ .vertices = 3, .instances = 1 });

    frame.cmd.cmdEndRendering();

    frame.cmd.cmdPipelineBarrier(.{
        .image = &.{frame.images.render_bkg.barrier(.{
            .src_access_mask = .{ .shader_write_bit = true },
            .src_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .src_layout = .general,
            .dst_layout = .general,
        })},
    });
}
