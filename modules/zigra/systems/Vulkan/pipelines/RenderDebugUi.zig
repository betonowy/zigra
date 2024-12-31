const std = @import("std");

const zvk = @import("zvk");
const spv = @import("spv");

const Frame = @import("../Frame.zig");
const Ubo = @import("../Ubo.zig");
const Atlas = @import("../Atlas.zig");

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
        .n_uniform_buffers = 1,
    });
    errdefer descriptor_pool.deinit();

    const descriptor_set_layout = try zvk.DescriptorSetLayout.init(device, &.{
        .{
            .binding = 0,
            .stage_flags = .{ .fragment_bit = true, .vertex_bit = true },
            .type = .uniform_buffer,
        },
        .{
            .binding = 1,
            .stage_flags = .{ .fragment_bit = true },
            .type = .combined_image_sampler,
            .count = Atlas.max_layers,
        },
        .{
            .binding = 2,
            .stage_flags = .{ .vertex_bit = true },
            .type = .storage_buffer,
        },
    });
    errdefer descriptor_set_layout.deinit();

    const pipeline_layout = try zvk.PipelineLayout.init(device, .{
        .dsls = &.{descriptor_set_layout},
    });
    errdefer pipeline_layout.deinit();

    const sm_vs = try zvk.ShaderModule.init(device, &spv.render_debug_ui_vert);
    defer sm_vs.deinit();

    const sm_fs = try zvk.ShaderModule.init(device, &spv.render_debug_ui_frag);
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
        .target_info = .{ .color_attachments = &.{.r8g8b8a8_srgb} },
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
    draw_buffer: zvk.Buffer,
    sampler: zvk.Sampler,
    atlas: Atlas,
    ubo: Ubo,
};

pub fn createFrameSet(self: @This(), frame: FrameResources) !zvk.DescriptorSet {
    const ds = try zvk.DescriptorSet.init(
        self.set_pool,
        self.set_layout,
    );
    errdefer ds.deinit();

    var ds_writes = std.BoundedArray(zvk.DescriptorSet.Write, 32){};

    ds_writes.appendSliceAssumeCapacity(&.{
        frame.ubo.getDescriptorSetWrite(ds, 0),
        frame.draw_buffer.getDescriptorSetWrite(ds, .{
            .binding = 2,
            .type = .storage_buffer,
        }),
    });

    try ds_writes.appendSlice(
        (try frame.atlas.getDescriptorSetWrite(ds, frame.sampler, 1)).constSlice(),
    );

    try ds.write(ds_writes.constSlice());

    return ds;
}

pub fn cmdRender(self: @This(), frame: *Frame) !void {
    const extent = @Vector(2, u32){
        frame.images.render_dui.options.extent[0],
        frame.images.render_dui.options.extent[1],
    };

    try frame.cmd.cmdBeginRendering(.{
        .render_area = .{ .offset = .{ 0, 0 }, .extent = extent },
        .color_attachments = &.{.{
            .view = .{ .handle = frame.views.render_dui.handle, .device = undefined },
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
            .layout = .color_attachment_optimal,
        }},
    });

    frame.cmd.cmdBindPipeline(.graphics, self.pipeline);

    try frame.cmd.cmdBindDescriptorSets(.graphics, self.layout, .{
        .slice = &.{frame.sets.render_dui},
    }, .{});

    try frame.cmd.cmdViewport(&.{.{ .size = @floatFromInt(extent) }});
    try frame.cmd.cmdScissor(&.{.{ .size = extent }});

    for (frame.dbs.dui.blocks.items) |blk| {
        switch (blk) {
            .scissor => |s| try frame.cmd.cmdScissor(&.{
                .{ .offset = s.offset, .size = s.extent },
            }),
            .triangles => |draw| frame.cmd.cmdDraw(.{
                .first_vertex = draw.begin,
                .vertices = draw.len,
                .instances = 1,
            }),
        }
    }

    frame.cmd.cmdEndRendering();

    frame.cmd.cmdPipelineBarrier(.{
        .image = &.{frame.images.render_dui.barrier(.{
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .dst_stage_mask = .{ .fragment_shader_bit = true },
            .src_layout = .color_attachment_optimal,
            .dst_layout = .shader_read_only_optimal,
        })},
    });
}
