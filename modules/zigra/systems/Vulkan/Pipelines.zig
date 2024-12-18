// const builtin = @import("builtin");
// const utils = @import("util");
const spv = @import("spv");
const std = @import("std");
const vk = @import("vk");

const Ctx = @import("Ctx.zig");
const builder = @import("Ctx/builder.zig");
const types = @import("Ctx/types.zig");

pub const Data = struct {
    handle: vk.Pipeline,
    layout: vk.PipelineLayout,
};

pub const Set = struct {
    sprite_opaque: Data,
    landscape: Data,
    line: Data,
    point: Data,
    triangles: Data,
    text: Data,
    present: Data,
    gui: Data,
};

ctx: *Ctx,
set: Set,

descriptor_set_layout: vk.DescriptorSetLayout,
depth_format: vk.Format,
depth_layout: vk.ImageLayout,
depth_aspect: vk.ImageAspectFlags,

pub fn init(ctx: *Ctx) !@This() {
    const depth_format = try ctx.findDepthImageFormat();

    const sprite_vs = try ctx.createShaderModule(&spv.sprite_vert);
    defer ctx.destroyShaderModule(sprite_vs);
    const sprite_opaque_fs = try ctx.createShaderModule(&spv.sprite_opaque_frag);
    defer ctx.destroyShaderModule(sprite_opaque_fs);
    const fullscreen_vs = try ctx.createShaderModule(&spv.fullscreen_vert);
    defer ctx.destroyShaderModule(fullscreen_vs);
    const present_fs = try ctx.createShaderModule(&spv.final_frag);
    defer ctx.destroyShaderModule(present_fs);
    const landscape_vs = try ctx.createShaderModule(&spv.landscape_vert);
    defer ctx.destroyShaderModule(landscape_vs);
    const landscape_fs = try ctx.createShaderModule(&spv.landscape_frag);
    defer ctx.destroyShaderModule(landscape_fs);
    const line_vs = try ctx.createShaderModule(&spv.line_vert);
    defer ctx.destroyShaderModule(line_vs);
    const line_opaque_fs = try ctx.createShaderModule(&spv.line_opaque_frag);
    defer ctx.destroyShaderModule(line_opaque_fs);
    const point_vs = try ctx.createShaderModule(&spv.point_vert);
    defer ctx.destroyShaderModule(point_vs);
    const point_fs = try ctx.createShaderModule(&spv.point_frag);
    defer ctx.destroyShaderModule(point_fs);
    const vertex_vs = try ctx.createShaderModule(&spv.vertex_vert);
    defer ctx.destroyShaderModule(vertex_vs);
    const vertex_fs = try ctx.createShaderModule(&spv.vertex_frag);
    defer ctx.destroyShaderModule(vertex_fs);
    const text_vs = try ctx.createShaderModule(&spv.text_vert);
    defer ctx.destroyShaderModule(text_vs);
    const text_fs = try ctx.createShaderModule(&spv.text_frag);
    defer ctx.destroyShaderModule(text_fs);

    const dsl = try ctx.createDescriptorSetLayout(&builder.pipeline.dslb_bindings);
    errdefer ctx.destroyDescriptorSetLayout(dsl);

    const pc_basic = builder.pipeline.pushConstantVsFs(@sizeOf(types.BasicPushConstant));
    const pc_text = builder.pipeline.pushConstantVsFs(@sizeOf(types.TextPushConstant));

    const point_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_basic} });
    errdefer ctx.destroyPipelineLayout(point_layout);
    const line_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_basic} });
    errdefer ctx.destroyPipelineLayout(line_layout);
    const landscape_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_basic} });
    errdefer ctx.destroyPipelineLayout(landscape_layout);
    const triangles_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_basic} });
    errdefer ctx.destroyPipelineLayout(triangles_layout);
    const text_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_text} });
    errdefer ctx.destroyPipelineLayout(text_layout);
    const sprite_opaque_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_basic} });
    errdefer ctx.destroyPipelineLayout(sprite_opaque_layout);
    const gui_layout = try ctx.createPipelineLayout(.{ .dsl = dsl, .pcr = &.{pc_basic} });
    errdefer ctx.destroyPipelineLayout(gui_layout);
    const present_layout = try ctx.createPipelineLayout(.{ .dsl = dsl });
    errdefer ctx.destroyPipelineLayout(present_layout);

    const middle_target_info = Ctx.PipelineRenderingCreateInfo{
        .color_attachments = &.{.r16g16b16a16_sfloat},
        .depth_attachment = depth_format,
    };

    const present_target_info = Ctx.PipelineRenderingCreateInfo{
        .color_attachments = &.{ctx.swapchain.format},
    };

    const default_rasterization = Ctx.PipelineRasterizationStateCreateInfo{
        .polygon_mode = .fill,
        .front_face = .clockwise,
    };

    const enabled_depth_attachment = Ctx.PipelineDepthStencilStateCreateInfo{
        .depth_test = .less_or_equal,
        .depth_write = true,
    };

    const disable_depth_attachment = Ctx.PipelineDepthStencilStateCreateInfo{
        .depth_test = .less,
        .depth_write = true,
    };

    const disabled_color_blending = Ctx.PipelineColorBlendStateCreateInfo{ .attachments = &.{.{}} };

    const enabled_color_blending = Ctx.PipelineColorBlendStateCreateInfo{
        .attachments = &.{Ctx.PipelineColorBlendAttachmentState{ .blend = .{
            .color_op = .add,
            .alpha_op = .add,
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .src_alpha_factor = .one,
            .dst_alpha_factor = .zero,
        } }},
        .blend_constants = .{ 0.5, 0.5, 0.5, 0.5 },
    };

    const view_scissor_dynamic_state: []const vk.DynamicState = &.{ .viewport, .scissor };

    const pipeline_point_opaque = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(point_vs, point_fs, .{}),
        .topology = .point_list,
        .rasterization = default_rasterization,
        .depth_stencil = enabled_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = point_layout,
        .target_info = middle_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_point_opaque);

    const pipeline_line_opaque = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(line_vs, line_opaque_fs, .{}),
        .topology = .line_list,
        .rasterization = default_rasterization,
        .depth_stencil = enabled_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = line_layout,
        .target_info = middle_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_line_opaque);

    const pipeline_landscape_opaque = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(landscape_vs, landscape_fs, .{}),
        .topology = .triangle_strip,
        .rasterization = default_rasterization,
        .depth_stencil = enabled_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = landscape_layout,
        .target_info = middle_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_landscape_opaque);

    const pipeline_triangle = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(vertex_vs, vertex_fs, .{}),
        .topology = .triangle_list,
        .rasterization = default_rasterization,
        .depth_stencil = enabled_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = triangles_layout,
        .target_info = middle_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_triangle);

    const pipeline_text = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(text_vs, text_fs, .{}),
        .topology = .triangle_strip,
        .rasterization = default_rasterization,
        .depth_stencil = enabled_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = text_layout,
        .target_info = middle_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_text);

    const pipeline_sprite_opaque = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(sprite_vs, sprite_opaque_fs, .{}),
        .topology = .triangle_strip,
        .rasterization = default_rasterization,
        .depth_stencil = enabled_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = sprite_opaque_layout,
        .target_info = middle_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_sprite_opaque);

    const pipeline_gui = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(vertex_vs, vertex_fs, .{}),
        .topology = .triangle_list,
        .rasterization = default_rasterization,
        .depth_stencil = disable_depth_attachment,
        .color_blend = enabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = gui_layout,
        .target_info = present_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_gui);

    const pipeline_present = try ctx.createGraphicsPipeline(.{
        .stages = &builder.pipeline.shader_stage.vsFs(fullscreen_vs, present_fs, .{}),
        .topology = .triangle_strip,
        .rasterization = default_rasterization,
        .depth_stencil = disable_depth_attachment,
        .color_blend = disabled_color_blending,
        .dynamic_states = view_scissor_dynamic_state,
        .layout = present_layout,
        .target_info = present_target_info,
    });
    errdefer ctx.destroyPipeline(pipeline_present);

    return @This(){
        .ctx = ctx,
        .set = .{
            .sprite_opaque = .{ .handle = pipeline_sprite_opaque, .layout = sprite_opaque_layout },
            .landscape = .{ .handle = pipeline_landscape_opaque, .layout = landscape_layout },
            .line = .{ .handle = pipeline_line_opaque, .layout = line_layout },
            .point = .{ .handle = pipeline_point_opaque, .layout = point_layout },
            .triangles = .{ .handle = pipeline_triangle, .layout = triangles_layout },
            .text = .{ .handle = pipeline_text, .layout = text_layout },
            .present = .{ .handle = pipeline_present, .layout = present_layout },
            .gui = .{ .handle = pipeline_gui, .layout = gui_layout },
        },
        .descriptor_set_layout = dsl,
        .depth_format = depth_format,
        .depth_layout = builder.depthImageLayout(depth_format),
        .depth_aspect = builder.depthImageAspect(depth_format),
    };
}

pub fn deinit(self: *@This()) void {
    self.ctx.destroyPipeline(self.set.sprite_opaque.handle);
    self.ctx.destroyPipelineLayout(self.set.sprite_opaque.layout);
    self.ctx.destroyPipeline(self.set.landscape.handle);
    self.ctx.destroyPipelineLayout(self.set.landscape.layout);
    self.ctx.destroyPipeline(self.set.line.handle);
    self.ctx.destroyPipelineLayout(self.set.line.layout);
    self.ctx.destroyPipeline(self.set.point.handle);
    self.ctx.destroyPipelineLayout(self.set.point.layout);
    self.ctx.destroyPipeline(self.set.triangles.handle);
    self.ctx.destroyPipelineLayout(self.set.triangles.layout);
    self.ctx.destroyPipeline(self.set.text.handle);
    self.ctx.destroyPipelineLayout(self.set.text.layout);
    self.ctx.destroyPipeline(self.set.present.handle);
    self.ctx.destroyPipelineLayout(self.set.present.layout);
    self.ctx.destroyPipeline(self.set.gui.handle);
    self.ctx.destroyPipelineLayout(self.set.gui.layout);
    self.ctx.destroyDescriptorSetLayout(self.descriptor_set_layout);
    self.* = undefined;
}

const CreatePipelineInfo = struct {
    depth_format: vk.Format,
};

fn destroyPipeline(ctx: *Ctx, data: Data) void {
    ctx.destroyPipelineLayout(data.layout);
    ctx.destroyPipeline(data.handle);
}
