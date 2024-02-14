const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const vk = @import("./vk.zig");
const types = @import("./vulkan_types.zig");
const initialization = @import("./vulkan_init.zig");
const Atlas = @import("VulkanAtlas.zig");

const zva = @import("./zva.zig");
const meta = @import("./meta.zig");

const stb = @cImport(@cInclude("stb/stb_image.h"));

const frame_data_count: u8 = 2;
const frame_max_draw_commands = 65536;
const frame_target_width = 640;
const frame_target_heigth = 480;
const frame_format = vk.Format.r16g16b16a16_sfloat;

allocator: std.mem.Allocator,

vkb: types.BaseDispatch,
vki: types.InstanceDispatch,
vkd: types.DeviceDispatch,
window_callbacks: *const types.WindowCallbacks,

instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
queue_families: types.QueueFamilyIndicesComplete,
debug_messenger: ?vk.DebugUtilsMessengerEXT,
surface: vk.SurfaceKHR,

graphic_queue: vk.Queue,
present_queue: vk.Queue,
graphic_command_pool: vk.CommandPool,

swapchain: types.SwapchainData,
descriptor_pool: vk.DescriptorPool,
frames: [frame_data_count]types.FrameData,
frame_index: @TypeOf(frame_data_count) = 0,
pipelines: types.Pipelines,
atlas: Atlas,

pub fn init(
    allocator: std.mem.Allocator,
    get_proc_addr: vk.PfnGetInstanceProcAddr,
    window_callbacks: *const types.WindowCallbacks,
) !@This() {
    var self: @This() = undefined;

    self.allocator = allocator;
    self.vkb = try types.BaseDispatch.load(get_proc_addr);

    self.instance = try initialization.createVulkanInstance(self.vkb, self.allocator, window_callbacks);
    self.vki = try types.InstanceDispatch.load(self.instance, get_proc_addr);
    errdefer self.vki.destroyInstance(self.instance, null);

    self.debug_messenger = try initialization.createDebugMessenger(self.vki, self.instance);
    errdefer if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (self.debug_messenger) |handle| self.vki.destroyDebugUtilsMessengerEXT(self.instance, handle, null);
    };

    self.window_callbacks = window_callbacks;
    self.surface = try self.window_callbacks.createWindowSurface(self.instance);
    errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

    self.physical_device = try initialization.pickPhysicalDevice(self.vki, self.instance, self.surface, allocator);
    self.queue_families = try initialization.findQueueFamilies(self.vki, self.physical_device, self.surface, allocator);
    self.device = try initialization.createLogicalDevice(self.vki, self.physical_device, self.queue_families);
    self.vkd = try types.DeviceDispatch.load(self.device, self.vki.dispatch.vkGetDeviceProcAddr);
    errdefer self.vkd.destroyDevice(self.device, null);

    try self.createSwapchain(.first_time);
    errdefer self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);

    self.descriptor_pool = try self.createDescriptorPool();
    errdefer self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    try self.createPipelines();
    errdefer self.destroyPipelines();

    self.graphic_queue = self.vkd.getDeviceQueue(self.device, self.queue_families.graphics, 0);
    self.present_queue = self.vkd.getDeviceQueue(self.device, self.queue_families.present, 0);

    try self.createCommandPools();
    errdefer self.destroyCommandPools();

    self.atlas = try Atlas.init(&self, &.{
        "images/crate_16.png",
        "images/ugly_cloud.png",
        "images/earth_01.png",
        "images/chunk_gold.png",
        "images/chunk_rock.png",
        "images/mountains/cut_01.png",
        "images/mountains/cut_02.png",
        "images/mountains/cut_03.png",
        "images/mountains/cut_04.png",
        "images/mountains/fog_06.png",
        "images/mountains/full_00.png",
    });
    errdefer self.atlas.deinit(&self);

    try self.createFrameData();
    errdefer self.destroyFrameData();

    return self;
}

pub fn deinit(self: *@This()) void {
    self.vkd.deviceWaitIdle(self.device) catch unreachable;

    self.atlas.deinit(self);
    self.destroyFrameData();
    self.destroyCommandPools();
    self.destroyPipelines();
    self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    for (self.swapchain.views.slice()) |view| {
        self.vkd.destroyImageView(self.device, view, null);
    }

    self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);
    self.vkd.destroyDevice(self.device, null);
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (self.debug_messenger) |handle| self.vki.destroyDebugUtilsMessengerEXT(self.instance, handle, null);
    }

    self.vki.destroyInstance(self.instance, null);
}

pub fn process(self: *@This()) !void {
    var timer = try std.time.Timer.start();

    const to_ms: f32 = 1e-6;
    _ = to_ms; // autofix

    if (try self.vkd.waitForFences(
        self.device,
        1,
        meta.asConstArray(&self.frames[self.frame_index].fence_busy),
        vk.TRUE,
        1_000_000_000,
    ) != .success) return error.FenceTimeout;

    const fence_dur: f32 = @floatFromInt(timer.lap());
    _ = fence_dur; // autofix

    const next_image = try self.acquireNextSwapchainImage();

    if (next_image.result == .error_out_of_date_khr) {
        try self.createSwapchain(.recreate);
        return;
    }

    const acquire_dur: f32 = @floatFromInt(timer.lap());
    _ = acquire_dur; // autofix

    try self.drawFrame(
        self.frames[self.frame_index],
        next_image.image_index,
    );

    const draw_dur: f32 = @floatFromInt(timer.lap());
    _ = draw_dur; // autofix

    const present_result = try self.presentSwapchainImage(
        self.frames[self.frame_index],
        next_image.image_index,
    );

    const present_dur: f32 = @floatFromInt(timer.lap());
    _ = present_dur; // autofix

    if (next_image.result != .success or present_result != .success) {
        try self.createSwapchain(.recreate);
    }

    // std.debug.print("fence: {d: >6.3} ms, acq: {d: >6.3} ms, draw: {d: >6.3} ms, p: {d: >6.3} ms, total: {d: >6.3} ms\n", .{
    //     fence_dur * to_ms,
    //     acquire_dur * to_ms,
    //     draw_dur * to_ms,
    //     present_dur * to_ms,
    //     (fence_dur + acquire_dur + draw_dur + present_dur) * to_ms,
    // });

    self.advanceFrame();
}

const CreateSwapchainMode = enum { first_time, recreate };

pub fn createSwapchain(self: *@This(), comptime mode: CreateSwapchainMode) !void {
    if (comptime mode == .recreate) {
        try self.vkd.deviceWaitIdle(self.device);

        for (self.swapchain.views.slice()) |view| {
            self.vkd.destroyImageView(self.device, view, null);
        }

        try self.swapchain.images.resize(0);
        try self.swapchain.views.resize(0);

        if (self.swapchain.handle != .null_handle) {
            self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);
        }
    }

    const basic_data = try initialization.createSwapChain(
        self.vki,
        self.vkd,
        self.physical_device,
        self.device,
        self.surface,
        self.window_callbacks,
        self.allocator,
    );
    self.swapchain = types.SwapchainData.init(basic_data);
    errdefer self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);

    var queried_image_count: u32 = undefined;

    if (try self.vkd.getSwapchainImagesKHR(self.device, self.swapchain.handle, &queried_image_count, null) != .success) {
        return error.InitializationFailed;
    }

    try self.swapchain.images.resize(queried_image_count);
    try self.swapchain.views.resize(queried_image_count);

    if (try self.vkd.getSwapchainImagesKHR(
        self.device,
        self.swapchain.handle,
        &queried_image_count,
        &self.swapchain.images.buffer,
    ) != .success) {
        return error.InitializationFailed;
    }

    for (self.swapchain.images.slice(), self.swapchain.views.slice(), 0..) |image, *view, i| {
        errdefer {
            for (self.swapchain.views.buffer[0..i]) |view_to_destroy| {
                self.vkd.destroyImageView(self.device, view_to_destroy, null);
            }

            self.swapchain.views.resize(0) catch unreachable;
        }

        view.* = try self.vkd.createImageView(self.device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = self.swapchain.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }
}

fn findMemoryType(self: *@This(), type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const props = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);

    for (0..props.memory_type_count) |i| {
        const properties_match = vk.MemoryPropertyFlags.contains(props.memory_types[i].property_flags, properties);
        const type_match = type_filter & @as(u32, 1) << @intCast(i) != 0;

        if (type_match and properties_match) return @intCast(i);
    }

    return error.MemoryTypeNotFound;
}

const CreateBufferInfo = struct {
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    sharing_mode: vk.SharingMode = .exclusive,
    properties: vk.MemoryPropertyFlags,
};

fn createBuffer(self: *@This(), comptime T: type, info: CreateBufferInfo) !types.BufferVisible(T) {
    const size_in_bytes = @sizeOf(T) * info.size;

    const buffer = try self.vkd.createBuffer(self.device, &.{
        .size = size_in_bytes,
        .usage = info.usage,
        .sharing_mode = info.sharing_mode,
    }, null);
    errdefer self.vkd.destroyBuffer(self.device, buffer, null);

    const memory_requirements = self.vkd.getBufferMemoryRequirements(self.device, buffer);

    const memory = try self.vkd.allocateMemory(self.device, &.{
        .allocation_size = memory_requirements.size,
        .memory_type_index = try self.findMemoryType(memory_requirements.memory_type_bits, info.properties),
    }, null);
    errdefer self.vkd.freeMemory(self.device, memory, null);

    try self.vkd.bindBufferMemory(self.device, buffer, memory, 0);
    const ptr = try self.vkd.mapMemory(self.device, memory, 0, size_in_bytes, .{});

    return types.BufferVisible(T){
        .handle = buffer,
        .requirements = memory_requirements,
        .memory = memory,
        .map = @as([*]T, @alignCast(@ptrCast(ptr)))[0..info.size],
    };
}

fn destroyBuffer(self: *@This(), typed_buffer: anytype) void {
    self.vkd.freeMemory(self.device, typed_buffer.memory, null);
    self.vkd.destroyBuffer(self.device, typed_buffer.handle, null);
}

const possible_depth_image_formats = [_]vk.Format{
    .d16_unorm,
    .d32_sfloat,
    .d16_unorm_s8_uint,
    .d24_unorm_s8_uint,
    .d32_sfloat_s8_uint,
};

fn findDepthImageFormat(self: @This()) !vk.Format {
    for (possible_depth_image_formats) |format| {
        const props = self.vki.getPhysicalDeviceFormatProperties(self.physical_device, format);
        if (props.optimal_tiling_features.depth_stencil_attachment_bit) {
            return format;
        }
    }

    return error.InitializationFailed;
}

const DepthImageType = enum {
    with_stencil,
    no_stencil,
};

fn formatHasStencil(format: vk.Format) DepthImageType {
    return switch (format) {
        .d16_unorm, .d32_sfloat => .no_stencil,
        else => .with_stencil,
    };
}

const ImageDataCreateInfo = struct {
    extent: vk.Extent2D,
    array_layers: u32 = 1,
    format: vk.Format,
    tiling: vk.ImageTiling = .optimal,
    initial_layout: vk.ImageLayout = .undefined,
    usage: vk.ImageUsageFlags,
    sharing_mode: vk.SharingMode = .exclusive,
    flags: vk.ImageCreateFlags = .{},
    property: vk.MemoryPropertyFlags,
    aspect_mask: vk.ImageAspectFlags,
    has_view: bool = true,
    map_memory: bool = false,
};

pub fn createImage(self: *@This(), info: ImageDataCreateInfo) !types.ImageData {
    const image = try self.vkd.createImage(self.device, &.{
        .image_type = .@"2d",
        .extent = .{
            .width = info.extent.width,
            .height = info.extent.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .format = info.format,
        .tiling = info.tiling,
        .initial_layout = info.initial_layout,
        .usage = info.usage,
        .sharing_mode = info.sharing_mode,
        .samples = .{ .@"1_bit" = true },
        .flags = info.flags,
    }, null);
    errdefer self.vkd.destroyImage(self.device, image, null);

    const memory_requirements = self.vkd.getImageMemoryRequirements(self.device, image);

    const memory = try self.vkd.allocateMemory(self.device, &.{
        .allocation_size = memory_requirements.size,
        .memory_type_index = try self.findMemoryType(memory_requirements.memory_type_bits, info.property),
    }, null);
    errdefer self.vkd.freeMemory(self.device, memory, null);

    const map = if (info.map_memory) try self.vkd.mapMemory(self.device, memory, 0, memory_requirements.size, .{}) else null;

    try self.vkd.bindImageMemory(self.device, image, memory, 0);

    if (!info.has_view) return .{
        .handle = image,
        .memory = memory,
        .requirements = memory_requirements,
        .format = info.format,
        .view = .null_handle,
        .aspect_mask = info.aspect_mask,
        .extent = info.extent,
        .map = map,
    };

    const view = try self.vkd.createImageView(self.device, &.{
        .image = image,
        .view_type = if (info.array_layers > 1) .@"2d_array" else .@"2d",
        .format = info.format,
        .subresource_range = .{
            .aspect_mask = info.aspect_mask,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = info.array_layers,
        },
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
    }, null);

    return .{
        .handle = image,
        .memory = memory,
        .requirements = memory_requirements,
        .format = info.format,
        .view = view,
        .aspect_mask = info.aspect_mask,
        .extent = info.extent,
        .map = map,
    };
}

pub fn destroyImage(self: *@This(), image_data: types.ImageData) void {
    if (image_data.view != .null_handle) self.vkd.destroyImageView(self.device, image_data.view, null);
    self.vkd.freeMemory(self.device, image_data.memory, null);
    self.vkd.destroyImage(self.device, image_data.handle, null);
}

fn createDescriptorPool(self: *@This()) !vk.DescriptorPool {
    const combined_image_samplers = vk.DescriptorPoolSize{
        .descriptor_count = 2,
        .type = .combined_image_sampler,
    };

    const storage_buffers = vk.DescriptorPoolSize{
        .descriptor_count = 1,
        .type = .storage_buffer,
    };

    const pool_sizes = [_]vk.DescriptorPoolSize{ combined_image_samplers, storage_buffers };

    return try self.vkd.createDescriptorPool(self.device, &.{
        .pool_size_count = 1,
        .p_pool_sizes = &pool_sizes,
        .max_sets = 2,
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
}

fn createShaderModule(self: *@This(), path: []const u8) !vk.ShaderModule {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const bytecode = try file.readToEndAllocOptions(self.allocator, stat.size, stat.size, @alignOf(u32), null);
    defer self.allocator.free(bytecode);

    const info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = @alignCast(@ptrCast(bytecode)),
    };

    return try self.vkd.createShaderModule(self.device, &info, null);
}

fn createPipelines(self: *@This()) !void {
    const triangle_vs = try self.createShaderModule("shaders/triangle.vert.spv");
    defer self.vkd.destroyShaderModule(self.device, triangle_vs, null);
    const triangle_fs = try self.createShaderModule("shaders/triangle.frag.spv");
    defer self.vkd.destroyShaderModule(self.device, triangle_fs, null);
    const present_vs = try self.createShaderModule("shaders/present.vert.spv");
    defer self.vkd.destroyShaderModule(self.device, present_vs, null);
    const present_fs = try self.createShaderModule("shaders/present.frag.spv");
    defer self.vkd.destroyShaderModule(self.device, present_fs, null);

    self.pipelines.resolved_depth_format = try self.findDepthImageFormat();

    self.pipelines.resolved_depth_aspect = switch (formatHasStencil(self.pipelines.resolved_depth_format)) {
        .with_stencil => .{ .depth_bit = true, .stencil_bit = true },
        .no_stencil => .{ .depth_bit = true },
    };

    self.pipelines.resolved_depth_layout = switch (formatHasStencil(self.pipelines.resolved_depth_format)) {
        .with_stencil => .depth_stencil_attachment_optimal,
        .no_stencil => .depth_attachment_optimal,
    };

    const triangle_shader_stage_create_info = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = triangle_vs,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = triangle_fs,
            .p_name = "main",
        },
    };

    const present_shader_stage_create_info = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = present_vs,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = present_fs,
            .p_name = "main",
        },
    };

    const dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = 2,
        .p_dynamic_states = &[_]vk.DynamicState{ .viewport, .scissor },
    };

    const assembly_stage_create_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_strip,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.swapchain.extent.width),
        .height = @floatFromInt(self.swapchain.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain.extent,
    };

    const viewport_state_create_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = meta.asConstArray(&viewport),
        .scissor_count = 1,
        .p_scissors = meta.asConstArray(&scissor),
    };

    const pipeline_rasterization_state_create_info = vk.PipelineRasterizationStateCreateInfo{ // OK
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1,
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const no_multisampling = vk.PipelineMultisampleStateCreateInfo{ // OK
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const opaque_color_blend_attachment = vk.PipelineColorBlendAttachmentState{ // OK
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    const depth_stencil_attachment = vk.PipelineDepthStencilStateCreateInfo{
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

    const no_depth_stencil_attachment = vk.PipelineDepthStencilStateCreateInfo{
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

    const no_color_blending = vk.PipelineColorBlendStateCreateInfo{ // OK
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{opaque_color_blend_attachment},
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const binding_ssb = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
    };

    const binding_atlas_img = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };

    const binding_target = vk.DescriptorSetLayoutBinding{
        .binding = 2,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };

    const bindings = [_]vk.DescriptorSetLayoutBinding{ binding_ssb, binding_atlas_img, binding_target };

    self.pipelines.descriptor_set_layout = try self.vkd.createDescriptorSetLayout(self.device, &.{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);
    errdefer self.vkd.destroyDescriptorSetLayout(self.device, self.pipelines.descriptor_set_layout, null);

    const vs_push_contant = vk.PushConstantRange{
        .size = 12,
        .offset = 0,
        .stage_flags = .{ .vertex_bit = true },
    };

    const fs_push_constant = vk.PushConstantRange{
        .size = 16,
        .offset = 0,
        .stage_flags = .{ .fragment_bit = true },
    };

    const push_constants = [_]vk.PushConstantRange{ vs_push_contant, fs_push_constant };

    self.pipelines.pipeline_sprite_opaque.layout = try self.vkd.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        .push_constant_range_count = push_constants.len,
        .p_push_constant_ranges = &push_constants,
    }, null);
    errdefer self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_sprite_opaque.layout, null);

    self.pipelines.pipeline_present.layout = try self.vkd.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    errdefer self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_sprite_opaque.layout, null);

    const sprite_opaque_render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = meta.asConstArray(&frame_format),
        .depth_attachment_format = self.pipelines.resolved_depth_format,
        .view_mask = 0,
        .stencil_attachment_format = .undefined,
    };

    const pipeline_sprite_opaque_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_dynamic_state = &dynamic_state_create_info,
        .p_stages = &triangle_shader_stage_create_info,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &assembly_stage_create_info,
        .p_viewport_state = &viewport_state_create_info,
        .p_rasterization_state = &pipeline_rasterization_state_create_info,
        .p_multisample_state = &no_multisampling,
        .p_depth_stencil_state = &depth_stencil_attachment,
        .p_color_blend_state = &no_color_blending,
        .layout = self.pipelines.pipeline_sprite_opaque.layout,
        .p_next = &sprite_opaque_render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    const present_render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = meta.asConstArray(&self.swapchain.format),
        .depth_attachment_format = .undefined,
        .view_mask = 0,
        .stencil_attachment_format = .undefined,
    };

    const pipeline_present_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_dynamic_state = &dynamic_state_create_info,
        .p_stages = &present_shader_stage_create_info,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &assembly_stage_create_info,
        .p_viewport_state = &viewport_state_create_info,
        .p_rasterization_state = &pipeline_rasterization_state_create_info,
        .p_multisample_state = &no_multisampling,
        .p_depth_stencil_state = &no_depth_stencil_attachment,
        .p_color_blend_state = &no_color_blending,
        .layout = self.pipelines.pipeline_sprite_opaque.layout,
        .p_next = &present_render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    if (try self.vkd.createGraphicsPipelines(
        self.device,
        .null_handle,
        1,
        meta.asConstArray(&pipeline_sprite_opaque_info),
        null,
        meta.asArray(&self.pipelines.pipeline_sprite_opaque.handle),
    ) != .success) return error.InitializationFailed;
    errdefer self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_sprite_opaque.handle, null);

    if (try self.vkd.createGraphicsPipelines(
        self.device,
        .null_handle,
        1,
        meta.asConstArray(&pipeline_present_info),
        null,
        meta.asArray(&self.pipelines.pipeline_present.handle),
    ) != .success) return error.InitializationFailed;
}

fn destroyPipelines(self: *@This()) void {
    self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_present.handle, null);
    self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_sprite_opaque.handle, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_present.layout, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_sprite_opaque.layout, null);
    self.vkd.destroyDescriptorSetLayout(self.device, self.pipelines.descriptor_set_layout, null);
}

fn createCommandPools(self: *@This()) !void {
    self.graphic_command_pool = try self.vkd.createCommandPool(self.device, &.{
        .queue_family_index = self.queue_families.graphics,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
}

fn destroyCommandPools(self: *@This()) void {
    self.vkd.destroyCommandPool(self.device, self.graphic_command_pool, null);
}

fn createFrameData(self: *@This()) !void {
    self.frames = .{ .{}, .{} };
    self.frame_index = 0;
    errdefer self.destroyFrameData();

    const image_extent = vk.Extent2D{ .width = frame_target_width, .height = frame_target_heigth };

    for (self.frames[0..]) |*frame| {
        frame.draw_buffer = try self.createBuffer(types.DrawData, .{
            .size = frame_max_draw_commands,
            .usage = .{ .storage_buffer_bit = true },
            .properties = .{ .host_visible_bit = true },
        });

        frame.image_color = try self.createImage(.{
            .extent = image_extent,
            .format = frame_format,
            .usage = .{ .color_attachment_bit = true, .sampled_bit = true },
            .property = .{ .device_local_bit = true },
            .aspect_mask = .{ .color_bit = true },
        });

        frame.image_depth = try self.createImage(.{
            .extent = image_extent,
            .format = self.pipelines.resolved_depth_format,
            .usage = .{ .depth_stencil_attachment_bit = true },
            .property = .{ .device_local_bit = true },
            .aspect_mask = self.pipelines.resolved_depth_aspect,
        });

        frame.image_color_sampler = try self.vkd.createSampler(self.device, &.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .clamp_to_border,
            .address_mode_v = .clamp_to_border,
            .address_mode_w = .clamp_to_border,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = undefined,
            .border_color = vk.BorderColor.int_transparent_black,
            .unnormalized_coordinates = vk.FALSE,
            .compare_enable = vk.FALSE,
            .compare_op = .never,
            .mipmap_mode = .nearest,
            .mip_lod_bias = 0,
            .min_lod = 0,
            .max_lod = 0,
        }, null);

        frame.fence_busy = try self.vkd.createFence(self.device, &.{ .flags = .{ .signaled_bit = true } }, null);
        frame.semaphore_finished = try self.vkd.createSemaphore(self.device, &.{}, null);
        frame.semaphore_swapchain_image_acquired = try self.vkd.createSemaphore(self.device, &.{}, null);

        try self.vkd.allocateDescriptorSets(self.device, &.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        }, meta.asArray(&frame.descriptor_set));

        try self.vkd.allocateCommandBuffers(self.device, &.{
            .command_buffer_count = 1,
            .level = .primary,
            .command_pool = self.graphic_command_pool,
        }, meta.asArray(&frame.command_buffer));

        const ds_ssb_info = vk.DescriptorBufferInfo{
            .buffer = frame.draw_buffer.handle,
            .offset = 0,
            .range = frame.draw_buffer.map.len,
        };

        const ds_atlas_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = self.atlas.image.view,
            .sampler = self.atlas.sampler,
        };

        const ds_target_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = frame.image_color.view,
            .sampler = frame.image_color_sampler,
        };

        const write_ssb = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .dst_array_element = 0,
            .dst_binding = 0,
            .dst_set = frame.descriptor_set,
            .p_buffer_info = meta.asConstArray(&ds_ssb_info),
        };

        const write_atlas = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = frame.descriptor_set,
            .p_image_info = meta.asConstArray(&ds_atlas_info),
        };

        const write_img = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 2,
            .dst_set = frame.descriptor_set,
            .p_image_info = meta.asConstArray(&ds_target_info),
        };

        const writes = [_]vk.WriteDescriptorSet{ write_ssb, write_atlas, write_img };

        self.vkd.updateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }
}

fn destroyFrameData(self: *@This()) void {
    for (self.frames[0..]) |frame| {
        if (frame.command_buffer != .null_handle) {
            self.vkd.freeCommandBuffers(
                self.device,
                self.graphic_command_pool,
                1,
                meta.asConstArray(&frame.command_buffer),
            );
        }

        if (frame.image_color_sampler != .null_handle) self.vkd.destroySampler(self.device, frame.image_color_sampler, null);
        if (frame.draw_buffer.handle != .null_handle) self.destroyBuffer(frame.draw_buffer);
        if (frame.image_color.handle != .null_handle) self.destroyImage(frame.image_color);
        if (frame.image_depth.handle != .null_handle) self.destroyImage(frame.image_depth);
        if (frame.fence_busy != .null_handle) self.vkd.destroyFence(self.device, frame.fence_busy, null);

        if (frame.semaphore_swapchain_image_acquired != .null_handle) {
            self.vkd.destroySemaphore(self.device, frame.semaphore_swapchain_image_acquired, null);
        }

        if (frame.semaphore_finished != .null_handle) {
            self.vkd.destroySemaphore(self.device, frame.semaphore_finished, null);
        }
    }
}

fn advanceFrame(self: *@This()) void {
    self.frame_index += 1;
    if (self.frame_index >= frame_data_count) self.frame_index = 0;
}

fn acquireNextSwapchainImage(self: *@This()) !types.DeviceDispatch.AcquireNextImageKHRResult {
    const next_image_result = self.vkd.acquireNextImageKHR(
        self.device,
        self.swapchain.handle,
        std.math.maxInt(u64),
        self.frames[self.frame_index].semaphore_swapchain_image_acquired,
        .null_handle,
    ) catch |err| {
        switch (err) {
            error.OutOfDateKHR => {
                std.log.err("Out of date swapchain!", .{});
                return .{ .result = .error_out_of_date_khr, .image_index = 0 };
            },
            else => return err,
        }
    };

    return next_image_result;
}

fn presentSwapchainImage(self: *@This(), frame: types.FrameData, swapchain_image_index: u32) !vk.Result {
    return self.vkd.queuePresentKHR(self.present_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = meta.asConstArray(&frame.semaphore_finished),
        .swapchain_count = 1,
        .p_swapchains = meta.asConstArray(&self.swapchain.handle),
        .p_image_indices = meta.asConstArray(&swapchain_image_index),
        .p_results = null,
    }) catch |err| {
        switch (err) {
            error.OutOfDateKHR => return .error_out_of_date_khr,
            else => return err,
        }
    };
}

fn drawFrame(self: *@This(), frame: types.FrameData, swapchain_image_index: u32) !void {
    try self.vkd.resetCommandBuffer(frame.command_buffer, .{});
    try self.vkd.beginCommandBuffer(frame.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    self.transitionFrameImagesBegin(frame);
    self.beginRenderingOpaque(frame);
    self.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.pipeline_sprite_opaque.handle);

    self.vkd.cmdBindDescriptorSets(
        frame.command_buffer,
        .graphics,
        self.pipelines.pipeline_sprite_opaque.layout,
        0,
        1,
        meta.asConstArray(&frame.descriptor_set),
        0,
        null,
    );

    self.vkd.cmdSetViewport(frame.command_buffer, 0, 1, meta.asConstArray(&vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(frame.image_color.extent.width),
        .height = @floatFromInt(frame.image_color.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }));

    self.vkd.cmdSetScissor(frame.command_buffer, 0, 1, meta.asConstArray(&vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = frame.image_color.extent,
    }));

    self.vkd.cmdEndRendering(frame.command_buffer);
    self.transitionFrameImagesFinal(frame, swapchain_image_index);
    self.beginRenderingFinal(frame, swapchain_image_index);
    self.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.pipeline_present.handle);

    const integer_scaling = integerScaling(self.swapchain.extent, self.atlas.image.extent);

    self.vkd.cmdSetViewport(frame.command_buffer, 0, 1, meta.asConstArray(&vk.Viewport{
        .x = @floatFromInt(integer_scaling.offset.x),
        .y = @floatFromInt(integer_scaling.offset.y),
        .width = @floatFromInt(integer_scaling.extent.width),
        .height = @floatFromInt(integer_scaling.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }));

    self.vkd.cmdSetScissor(frame.command_buffer, 0, 1, meta.asConstArray(&integer_scaling));

    self.vkd.cmdDraw(frame.command_buffer, 3, 1, 0, 0);
    self.vkd.cmdEndRendering(frame.command_buffer);
    self.transitionFrameImagesPresent(frame, swapchain_image_index);
    try self.vkd.endCommandBuffer(frame.command_buffer);

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = meta.asConstArray(&frame.semaphore_swapchain_image_acquired),
        .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }},
        .command_buffer_count = 1,
        .p_command_buffers = meta.asConstArray(&frame.command_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = meta.asConstArray(&frame.semaphore_finished),
    };

    try self.vkd.resetFences(self.device, 1, meta.asConstArray(&frame.fence_busy));
    try self.vkd.queueSubmit(self.graphic_queue, 1, meta.asConstArray(&submit_info), frame.fence_busy);
}

fn transitionFrameImagesBegin(self: *@This(), frame: types.FrameData) void {
    const depth_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = .undefined,
        .new_layout = self.pipelines.resolved_depth_layout,
        .image = frame.image_depth.handle,
        .subresource_range = .{
            .aspect_mask = frame.image_depth.aspect_mask,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const color_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = .undefined,
        .new_layout = .color_attachment_optimal,
        .image = frame.image_color.handle,
        .subresource_range = .{
            .aspect_mask = frame.image_color.aspect_mask,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const barriers = [_]vk.ImageMemoryBarrier2{ depth_image_barrier, color_image_barrier };

    self.vkd.cmdPipelineBarrier2(frame.command_buffer, &.{
        .image_memory_barrier_count = barriers.len,
        .p_image_memory_barriers = &barriers,
    });
}

fn beginRenderingOpaque(self: *@This(), frame: types.FrameData) void {
    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = frame.image_color.view,
        .image_layout = .color_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    };

    const depth_attachment = vk.RenderingAttachmentInfo{
        .image_view = frame.image_depth.view,
        .image_layout = .depth_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };

    self.vkd.cmdBeginRendering(frame.command_buffer, &.{
        .color_attachment_count = 1,
        .p_color_attachments = meta.asConstArray(&color_attachment),
        .p_depth_attachment = &depth_attachment,
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = frame.image_color.extent },
        .layer_count = 1,
        .view_mask = 0,
    });
}

fn transitionFrameImagesFinal(self: *@This(), frame: types.FrameData, swapchain_image_index: u32) void {
    const swapchain_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = .undefined,
        .new_layout = .color_attachment_optimal,
        .image = self.swapchain.images.get(swapchain_image_index),
        .subresource_range = .{
            .aspect_mask = frame.image_color.aspect_mask,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const color_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = .color_attachment_optimal,
        .new_layout = .shader_read_only_optimal,
        .image = frame.image_color.handle,
        .subresource_range = .{
            .aspect_mask = frame.image_color.aspect_mask,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    const barriers = [_]vk.ImageMemoryBarrier2{ swapchain_image_barrier, color_image_barrier };

    self.vkd.cmdPipelineBarrier2(frame.command_buffer, &.{
        .image_memory_barrier_count = barriers.len,
        .p_image_memory_barriers = &barriers,
    });
}

fn beginRenderingFinal(self: *@This(), frame: types.FrameData, swapchain_image_index: u32) void {
    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = self.swapchain.views.get(swapchain_image_index),
        .image_layout = .color_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .clear_value = .{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 0.1 } } },
    };

    self.vkd.cmdBeginRendering(frame.command_buffer, &.{
        .color_attachment_count = 1,
        .p_color_attachments = meta.asConstArray(&color_attachment),
        .p_depth_attachment = null,
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent },
        .layer_count = 1,
        .view_mask = 0,
    });
}

fn transitionFrameImagesPresent(self: *@This(), frame: types.FrameData, swapchain_image_index: u32) void {
    const swapchain_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = .color_attachment_optimal,
        .new_layout = .present_src_khr,
        .image = self.swapchain.images.get(swapchain_image_index),
        .subresource_range = .{
            .aspect_mask = frame.image_color.aspect_mask,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    self.vkd.cmdPipelineBarrier2(frame.command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = meta.asConstArray(&swapchain_image_barrier),
    });
}

fn integerScaling(dst: vk.Extent2D, src: vk.Extent2D) vk.Rect2D {
    const width_scale = dst.width / src.width;
    const height_scale = dst.height / src.height;
    const scale = @max(1, @min(width_scale, height_scale));

    if (dst.width < src.width or dst.height < src.height) return vk.Rect2D{
        .extent = src,
        .offset = .{ .x = 0, .y = 0 },
    };

    return vk.Rect2D{
        .extent = .{
            .width = src.width * scale,
            .height = src.height * scale,
        },
        .offset = .{
            .x = @intCast((dst.width - (src.width * scale)) / 2),
            .y = @intCast((dst.height - (src.height * scale)) / 2),
        },
    };
}
