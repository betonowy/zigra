const std = @import("std");

const util = @import("util");
const vk = @import("vk");

const Device = @import("Device.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const ShaderModule = @import("ShaderModule.zig");

device: *Device,
handle: vk.Pipeline,

pub const PipelineRasterizationStateCreateInfo = struct {
    depth_clamp: bool = false,
    discard: bool = false,
    polygon_mode: vk.PolygonMode,
    cull_mode: vk.CullModeFlags = .{},
    front_face: vk.FrontFace,
    depth_bias: ?struct {
        constant_factor: f32,
        clamp: f32,
        slope_factor: f32,
    } = null,
    line_width: f32 = 1,
};

pub const PipelineDepthStencilStateCreateInfo = struct {
    depth_test: ?vk.CompareOp = null,
    depth_write: bool = false,
    stencil_test: ?struct {
        front: vk.StencilOpState,
        back: vk.StencilOpState,
    } = null,
    bounds_test: ?struct {
        min: f32,
        max: f32,
    } = null,
};

pub const PipelineColorBlendAttachmentState = struct {
    blend: ?struct {
        color_op: vk.BlendOp,
        src_color_factor: vk.BlendFactor,
        dst_color_factor: vk.BlendFactor,
        alpha_op: vk.BlendOp,
        src_alpha_factor: vk.BlendFactor,
        dst_alpha_factor: vk.BlendFactor,
    } = null,
    color_write_mask: vk.ColorComponentFlags = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
};

pub const PipelineColorBlendStateCreateInfo = struct {
    logic_op: ?vk.LogicOp = null,
    attachments: []const PipelineColorBlendAttachmentState,
    blend_constants: @Vector(4, f32) = .{ 1, 1, 1, 1 },
};

pub const PipelineRenderingCreateInfo = struct {
    view_mask: u32 = 0,
    color_attachments: []const vk.Format = &.{},
    depth_attachment: ?vk.Format = null,
    stencil_attachment: ?vk.Format = null,
};

pub const GraphicsPipelineCreateInfo = struct {
    flags: vk.PipelineCreateFlags = .{},
    stages: []const vk.PipelineShaderStageCreateInfo,
    topology: vk.PrimitiveTopology,
    viewports: ?[]const vk.Viewport = null,
    scissors: ?[]const vk.Rect2D = null,
    rasterization: PipelineRasterizationStateCreateInfo,
    depth_stencil: PipelineDepthStencilStateCreateInfo,
    color_blend: PipelineColorBlendStateCreateInfo,
    dynamic_states: []const vk.DynamicState = &.{},
    layout: PipelineLayout,
    target_info: PipelineRenderingCreateInfo,
};

pub fn initGraphics(device: *Device, info: GraphicsPipelineCreateInfo) !@This() {
    var color_attachments = std.BoundedArray(vk.PipelineColorBlendAttachmentState, 64){};

    for (info.color_blend.attachments) |a| try color_attachments.append(.{
        .blend_enable = if (a.blend != null) vk.TRUE else vk.FALSE,
        .color_write_mask = a.color_write_mask,
        .color_blend_op = if (a.blend) |b| b.color_op else undefined,
        .src_color_blend_factor = if (a.blend) |b| b.src_color_factor else undefined,
        .dst_color_blend_factor = if (a.blend) |b| b.dst_color_factor else undefined,
        .alpha_blend_op = if (a.blend) |b| b.alpha_op else undefined,
        .src_alpha_blend_factor = if (a.blend) |b| b.src_alpha_factor else undefined,
        .dst_alpha_blend_factor = if (a.blend) |b| b.dst_alpha_factor else undefined,
    });

    const vk_create_info = [_]vk.GraphicsPipelineCreateInfo{.{
        .flags = info.flags,
        .stage_count = @intCast(info.stages.len),
        .p_stages = info.stages.ptr,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{
            .topology = info.topology,
            .primitive_restart_enable = vk.FALSE,
        },
        .p_viewport_state = &.{
            .viewport_count = @intCast(if (info.viewports) |v| v.len else 1),
            .p_viewports = if (info.viewports) |v| v.ptr else &[_]vk.Viewport{std.mem.zeroes(vk.Viewport)},
            .scissor_count = @intCast(if (info.scissors) |s| s.len else 1),
            .p_scissors = if (info.scissors) |s| s.ptr else &[_]vk.Rect2D{std.mem.zeroes(vk.Rect2D)},
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = if (info.rasterization.depth_clamp) vk.TRUE else vk.FALSE,
            .rasterizer_discard_enable = if (info.rasterization.discard) vk.TRUE else vk.FALSE,
            .polygon_mode = info.rasterization.polygon_mode,
            .cull_mode = info.rasterization.cull_mode,
            .front_face = info.rasterization.front_face,
            .depth_bias_enable = if (info.rasterization.depth_bias != null) vk.TRUE else vk.FALSE,
            .depth_bias_constant_factor = if (info.rasterization.depth_bias) |db| db.constant_factor else 0,
            .depth_bias_clamp = if (info.rasterization.depth_bias) |db| db.clamp else 0,
            .depth_bias_slope_factor = if (info.rasterization.depth_bias) |db| db.slope_factor else 0,
            .line_width = info.rasterization.line_width,
        },
        .p_multisample_state = &.{
            .sample_shading_enable = vk.FALSE,
            .rasterization_samples = .{ .@"1_bit" = true },
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        },
        .p_dynamic_state = if (info.dynamic_states.len == 0) null else &.{
            .dynamic_state_count = @intCast(info.dynamic_states.len),
            .p_dynamic_states = info.dynamic_states.ptr,
        },
        .p_depth_stencil_state = &.{
            .depth_test_enable = if (info.depth_stencil.depth_test != null) vk.TRUE else vk.FALSE,
            .depth_compare_op = info.depth_stencil.depth_test orelse undefined,
            .depth_write_enable = if (info.depth_stencil.depth_write) vk.TRUE else vk.FALSE,
            .stencil_test_enable = if (info.depth_stencil.stencil_test != null) vk.TRUE else vk.FALSE,
            .front = if (info.depth_stencil.stencil_test) |s| s.front else undefined,
            .back = if (info.depth_stencil.stencil_test) |s| s.back else undefined,
            .depth_bounds_test_enable = if (info.depth_stencil.bounds_test != null) vk.TRUE else vk.FALSE,
            .min_depth_bounds = if (info.depth_stencil.bounds_test) |b| b.min else undefined,
            .max_depth_bounds = if (info.depth_stencil.bounds_test) |b| b.max else undefined,
        },
        .p_color_blend_state = &.{
            .attachment_count = @intCast(color_attachments.constSlice().len),
            .p_attachments = color_attachments.constSlice().ptr,
            .blend_constants = info.color_blend.blend_constants,
            .logic_op_enable = if (info.color_blend.logic_op != null) vk.TRUE else vk.FALSE,
            .logic_op = info.color_blend.logic_op orelse undefined,
        },
        .p_next = &vk.PipelineRenderingCreateInfo{
            .color_attachment_count = @intCast(info.target_info.color_attachments.len),
            .p_color_attachment_formats = info.target_info.color_attachments.ptr,
            .depth_attachment_format = info.target_info.depth_attachment orelse .undefined,
            .stencil_attachment_format = info.target_info.stencil_attachment orelse .undefined,
            .view_mask = info.target_info.view_mask,
        },
        .layout = info.layout.handle,
        .subpass = 0,
        .base_pipeline_index = 0,
    }};

    var pipeline: [1]vk.Pipeline = undefined;

    return .{
        .device = device,
        .handle = if (try device.api.createGraphicsPipelines(
            device.handle,
            .null_handle,
            @intCast(vk_create_info.len),
            &vk_create_info,
            null,
            &pipeline,
        ) != .success) return error.createGraphicsPipelinesFailed else pipeline[0],
    };
}

pub const ComputePipelineCreateInfo = struct {
    stage: Stage,
    layout: PipelineLayout,

    pub const Stage = struct {
        module: ShaderModule,
        entry: [:0]const u8 = "main",
    };
};

pub fn initCompute(device: *Device, info: ComputePipelineCreateInfo) !@This() {
    const vk_info = [_]vk.ComputePipelineCreateInfo{.{
        .base_pipeline_index = 0,
        .stage = .{
            .module = info.stage.module.handle,
            .p_name = info.stage.entry,
            .stage = .{ .compute_bit = true },
        },
        .layout = info.layout.handle,
    }};

    var pipeline: [1]vk.Pipeline = undefined;

    return .{
        .device = device,
        .handle = if (try device.api.createComputePipelines(
            device.handle,
            .null_handle,
            @intCast(vk_info.len),
            &vk_info,
            null,
            &pipeline,
        ) != .success) return error.createComputePipelineFailed else pipeline[0],
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyPipeline(self.device.handle, self.handle, null);
}
