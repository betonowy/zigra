const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const vk = @import("vk");
const types = @import("types.zig");
const initialization = @import("init.zig");
const Atlas = @import("../Atlas.zig");
const Landscape = @import("../Landscape.zig");
const spv = @import("spv");

const stb = @cImport(@cInclude("stb/stb_image.h"));

pub fn depthImageAspect(format: vk.Format) vk.ImageAspectFlags {
    return switch (format) {
        .d16_unorm, .d32_sfloat => .{ .depth_bit = true },
        else => .{ .depth_bit = true, .stencil_bit = true },
    };
}

pub fn depthImageLayout(format: vk.Format) vk.ImageLayout {
    return switch (format) {
        .d16_unorm, .d32_sfloat => .depth_attachment_optimal,
        else => .depth_stencil_attachment_optimal,
    };
}

pub const compIdentity = vk.ComponentMapping{
    .r = .identity,
    .g = .identity,
    .b = .identity,
    .a = .identity,
};

pub fn defaultSubrange(aspect: vk.ImageAspectFlags, array_layers: u32) vk.ImageSubresourceRange {
    return .{
        .aspect_mask = aspect,
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = array_layers,
    };
}

pub const pipeline = struct {
    pub const shader_stage = struct {
        pub const Names = struct {
            vs: [:0]const u8 = "main",
            fs: [:0]const u8 = "main",
        };

        pub fn vsFs(
            vs: vk.ShaderModule,
            fs: vk.ShaderModule,
            entries: Names,
        ) [2]vk.PipelineShaderStageCreateInfo {
            return .{
                .{
                    .stage = .{ .vertex_bit = true },
                    .module = vs,
                    .p_name = entries.vs.ptr,
                },
                .{
                    .stage = .{ .fragment_bit = true },
                    .module = fs,
                    .p_name = entries.fs.ptr,
                },
            };
        }
    };

    const DynamicStateType = enum {
        minimal,
    };

    pub fn dynamicState(comptime info_type: DynamicStateType) vk.PipelineDynamicStateCreateInfo {
        const minimal_states = [_]vk.DynamicState{ .viewport, .scissor };

        return switch (info_type) {
            .minimal => .{
                .dynamic_state_count = minimal_states.len,
                .p_dynamic_states = &minimal_states,
            },
        };
    }

    pub fn assemblyState(comptime topology: vk.PrimitiveTopology) vk.PipelineInputAssemblyStateCreateInfo {
        return .{ .topology = topology, .primitive_restart_enable = vk.FALSE };
    }

    pub const dummy_viewport = &[_]vk.Viewport{std.mem.zeroes(vk.Viewport)};
    pub const dummy_scissor = &[_]vk.Rect2D{std.mem.zeroes(vk.Rect2D)};

    pub const dummy_viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = dummy_viewport,
        .scissor_count = 1,
        .p_scissors = dummy_scissor,
    };

    pub const default_rasterization = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1,
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .cull_mode = .{},
    };

    pub const disabled_multisampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    pub const opaque_color_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    pub const disabled_color_blending = vk.PipelineColorBlendStateCreateInfo{ // OK
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{opaque_color_attachment},
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    pub const enabled_depth_attachment = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.TRUE,
        .depth_compare_op = .less_or_equal,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = undefined,
        .max_depth_bounds = undefined,
    };

    pub const disabled_depth_attachment = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.TRUE,
        .depth_compare_op = .less,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = undefined,
        .max_depth_bounds = undefined,
    };

    pub const dslb_draw_buffer = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
    };

    pub const dslb_atlas_img = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };

    pub const dslb_target_img = vk.DescriptorSetLayoutBinding{
        .binding = 2,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };

    pub const dslb_landscape_img = vk.DescriptorSetLayoutBinding{
        .binding = 3,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = Landscape.tile_count,
        .stage_flags = .{ .fragment_bit = true },
    };

    pub const dslb_bindings = [_]vk.DescriptorSetLayoutBinding{
        dslb_draw_buffer,
        dslb_atlas_img,
        dslb_target_img,
        dslb_landscape_img,
    };

    fn countDescriptors(bindings: []const vk.DescriptorSetLayoutBinding) u32 {
        var sum: u32 = 0;
        for (bindings) |binding| sum += binding.descriptor_count;
        return sum;
    }

    const dps_combined_image_samplers = vk.DescriptorPoolSize{
        .descriptor_count = countDescriptors(&.{ dslb_atlas_img, dslb_target_img, dslb_landscape_img }),
        .type = .combined_image_sampler,
    };

    const dps_storage_buffers = vk.DescriptorPoolSize{
        .descriptor_count = countDescriptors(&.{dslb_draw_buffer}),
        .type = .storage_buffer,
    };

    pub const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{ dps_combined_image_samplers, dps_storage_buffers };

    pub fn pushConstantVsFs(size: u32) vk.PushConstantRange {
        return .{
            .size = size,
            .offset = 0,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        };
    }
};

pub const frame = struct {};
