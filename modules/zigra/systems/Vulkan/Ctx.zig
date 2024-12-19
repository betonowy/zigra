const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vk");

const util = @import("util");

const VkAllocator = @import("Ctx/VkAllocator.zig");
const types = @import("Ctx/types.zig");
const initialization = @import("Ctx/init.zig");
const builder = @import("Ctx/builder.zig");

const log = std.log.scoped(.Vulkan_Ctx);

fn flagConcat(flags: anytype) @TypeOf(flags[0]) {
    var a = flags[0];
    for (flags[0..]) |f| {
        var v: u32 = @intFromEnum(a);
        v |= @intFromEnum(f);
        a = @enumFromInt(v);
    }
    return a;
}

allocator: std.mem.Allocator,

vka: VkAllocator,
vkb: types.BaseDispatch,
vki: types.InstanceDispatch,
vkd: types.DeviceDispatch,
window_callbacks: *const types.WindowCallbacks,

instance: vk.Instance,
physical_device: vk.PhysicalDevice,
limits: vk.PhysicalDeviceLimits,
device: vk.Device,
queue_families: types.QueueFamilyIndicesComplete,
debug_messenger: ?vk.DebugUtilsMessengerEXT,
surface: vk.SurfaceKHR,

graphic_queue: vk.Queue,
present_queue: vk.Queue,
graphic_command_pool: vk.CommandPool,

swapchain: types.SwapchainData,
descriptor_pool: vk.DescriptorPool,

pub fn init(
    allocator: std.mem.Allocator,
    get_proc_addr: vk.PfnGetInstanceProcAddr,
    window_callbacks: *const types.WindowCallbacks,
) !*@This() {
    const self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.vka = try VkAllocator.init(allocator);
    errdefer self.vka.deinit();

    self.vkb = try types.BaseDispatch.load(get_proc_addr);
    self.instance = try initialization.createVulkanInstance(self.vkb, self.allocator, window_callbacks, self.vka);
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
    {
        var p: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        self.vki.getPhysicalDeviceProperties2(self.physical_device, &p);
        log.info("Selected: {s}, vendor ID: 0x{x}", .{ p.properties.device_name, p.properties.vendor_id });
        self.limits = p.properties.limits;
    }

    self.queue_families = try initialization.findQueueFamilies(self.vki, self.physical_device, self.surface, allocator);
    self.device = try initialization.createLogicalDevice(self.vki, self.physical_device, self.queue_families);
    self.vkd = try types.DeviceDispatch.load(self.device, self.vki.dispatch.vkGetDeviceProcAddr);
    errdefer self.vkd.destroyDevice(self.device, null);

    try self.initSwapchain(.first_time);
    errdefer self.deinitSwapchain();

    self.descriptor_pool = try self.vkd.createDescriptorPool(self.device, &.{
        .pool_size_count = builder.pipeline.descriptor_pool_sizes.len,
        .p_pool_sizes = &builder.pipeline.descriptor_pool_sizes,
        .max_sets = 16,
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
    errdefer self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    self.graphic_queue = self.vkd.getDeviceQueue(self.device, self.queue_families.graphics, 0);
    self.present_queue = self.vkd.getDeviceQueue(self.device, self.queue_families.present, 0);

    try self.createCommandPools();
    errdefer self.destroyCommandPools();

    return self;
}

pub fn deinit(self: *@This()) void {
    self.waitIdle();

    self.destroyCommandPools();
    self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    self.deinitSwapchain();
    self.vkd.destroyDevice(self.device, null);
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (self.debug_messenger) |handle| self.vki.destroyDebugUtilsMessengerEXT(self.instance, handle, null);
    }

    self.vki.destroyInstance(self.instance, &self.vka.cbs);
    self.vka.deinit();

    self.allocator.destroy(self);
}

const InitSwapchainMode = enum { first_time, recreate };

fn initSwapchain(self: *@This(), comptime mode: InitSwapchainMode) !void {
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
            .components = builder.compIdentity,
            .subresource_range = builder.defaultSubrange(.{ .color_bit = true }, 1),
        }, null);
    }
}

fn deinitSwapchain(self: *@This()) void {
    for (self.swapchain.views.slice()) |view| {
        self.vkd.destroyImageView(self.device, view, null);
    }

    self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);
}

pub fn recreateSwapchain(self: *@This()) !void {
    try self.initSwapchain(.recreate);
}

pub fn waitIdle(self: *@This()) void {
    self.vkd.deviceWaitIdle(self.device) catch @panic("vkDeviceWaitIdle failed");
}

pub fn findDepthImageFormat(self: *@This()) !vk.Format {
    const possible_depth_image_formats = [_]vk.Format{
        .d16_unorm,
        .d32_sfloat,
        .d16_unorm_s8_uint,
        .d24_unorm_s8_uint,
        .d32_sfloat_s8_uint,
    };

    for (possible_depth_image_formats) |format| {
        const props = self.vki.getPhysicalDeviceFormatProperties(self.physical_device, format);
        if (props.optimal_tiling_features.depth_stencil_attachment_bit) {
            return format;
        }
    }

    return error.oops;
}

pub fn createShaderModule(self: *@This(), spirv_code: []const u32) !vk.ShaderModule {
    return self.vkd.createShaderModule(self.device, &.{
        .code_size = spirv_code.len * @sizeOf(std.meta.Child(@TypeOf(spirv_code))),
        .p_code = @alignCast(@ptrCast(spirv_code)),
    }, null);
}

pub fn destroyShaderModule(self: *@This(), module: vk.ShaderModule) void {
    self.vkd.destroyShaderModule(self.device, module, null);
}

pub fn createDescriptorSetLayout(self: *@This(), bindings: []const vk.DescriptorSetLayoutBinding) !vk.DescriptorSetLayout {
    return self.vkd.createDescriptorSetLayout(self.device, &.{
        .binding_count = @intCast(bindings.len),
        .p_bindings = bindings.ptr,
    }, null);
}

pub fn destroyDescriptorSetLayout(self: *@This(), dsl: vk.DescriptorSetLayout) void {
    self.vkd.destroyDescriptorSetLayout(self.device, dsl, null);
}

pub const CreatePipelineLayout = struct {
    flags: vk.PipelineLayoutCreateFlags = .{},
    pcr: []const vk.PushConstantRange = &.{},
    dsl: vk.DescriptorSetLayout,
};

pub fn createPipelineLayout(self: @This(), create_info: CreatePipelineLayout) !vk.PipelineLayout {
    const vk_create_info = vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .p_set_layouts = util.meta.asConstArray(&create_info.dsl),
        .set_layout_count = 1,
        .p_push_constant_ranges = create_info.pcr.ptr,
        .push_constant_range_count = @intCast(create_info.pcr.len),
    };

    return try self.vkd.createPipelineLayout(self.device, &vk_create_info, null);
}

pub fn destroyPipelineLayout(self: *@This(), layout: vk.PipelineLayout) void {
    self.vkd.destroyPipelineLayout(self.device, layout, null);
}

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
    layout: vk.PipelineLayout = .null_handle,
    target_info: PipelineRenderingCreateInfo,
};

pub fn createGraphicsPipeline(self: *@This(), create_info: GraphicsPipelineCreateInfo) !vk.Pipeline {
    var pipeline: vk.Pipeline = undefined;

    var color_attachments = try std.ArrayList(vk.PipelineColorBlendAttachmentState)
        .initCapacity(self.allocator, create_info.color_blend.attachments.len);
    defer color_attachments.deinit();

    for (create_info.color_blend.attachments) |a| color_attachments.appendAssumeCapacity(.{
        .blend_enable = if (a.blend != null) vk.TRUE else vk.FALSE,
        .color_write_mask = a.color_write_mask,
        .color_blend_op = if (a.blend) |b| b.color_op else undefined,
        .src_color_blend_factor = if (a.blend) |b| b.src_color_factor else undefined,
        .dst_color_blend_factor = if (a.blend) |b| b.dst_color_factor else undefined,
        .alpha_blend_op = if (a.blend) |b| b.alpha_op else undefined,
        .src_alpha_blend_factor = if (a.blend) |b| b.src_alpha_factor else undefined,
        .dst_alpha_blend_factor = if (a.blend) |b| b.dst_alpha_factor else undefined,
    });

    const vk_create_info = vk.GraphicsPipelineCreateInfo{
        .flags = create_info.flags,
        .stage_count = @intCast(create_info.stages.len),
        .p_stages = create_info.stages.ptr,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{
            .topology = create_info.topology,
            .primitive_restart_enable = vk.FALSE,
        },
        .p_viewport_state = &.{
            .viewport_count = @intCast(if (create_info.viewports) |v| v.len else 1),
            .p_viewports = if (create_info.viewports) |v| v.ptr else builder.pipeline.dummy_viewport,
            .scissor_count = @intCast(if (create_info.scissors) |s| s.len else 1),
            .p_scissors = if (create_info.scissors) |s| s.ptr else builder.pipeline.dummy_scissor,
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = if (create_info.rasterization.depth_clamp) vk.TRUE else vk.FALSE,
            .rasterizer_discard_enable = if (create_info.rasterization.discard) vk.TRUE else vk.FALSE,
            .polygon_mode = create_info.rasterization.polygon_mode,
            .cull_mode = create_info.rasterization.cull_mode,
            .front_face = create_info.rasterization.front_face,
            .depth_bias_enable = if (create_info.rasterization.depth_bias != null) vk.TRUE else vk.FALSE,
            .depth_bias_constant_factor = if (create_info.rasterization.depth_bias) |db| db.constant_factor else 0,
            .depth_bias_clamp = if (create_info.rasterization.depth_bias) |db| db.clamp else 0,
            .depth_bias_slope_factor = if (create_info.rasterization.depth_bias) |db| db.slope_factor else 0,
            .line_width = create_info.rasterization.line_width,
        },
        .p_multisample_state = &builder.pipeline.disabled_multisampling,
        .p_dynamic_state = if (create_info.dynamic_states.len == 0) null else &.{
            .dynamic_state_count = @intCast(create_info.dynamic_states.len),
            .p_dynamic_states = create_info.dynamic_states.ptr,
        },
        .p_depth_stencil_state = &.{
            .depth_test_enable = if (create_info.depth_stencil.depth_test != null) vk.TRUE else vk.FALSE,
            .depth_compare_op = create_info.depth_stencil.depth_test orelse undefined,
            .depth_write_enable = if (create_info.depth_stencil.depth_write) vk.TRUE else vk.FALSE,
            .stencil_test_enable = if (create_info.depth_stencil.stencil_test != null) vk.TRUE else vk.FALSE,
            .front = if (create_info.depth_stencil.stencil_test) |s| s.front else undefined,
            .back = if (create_info.depth_stencil.stencil_test) |s| s.back else undefined,
            .depth_bounds_test_enable = if (create_info.depth_stencil.bounds_test != null) vk.TRUE else vk.FALSE,
            .min_depth_bounds = if (create_info.depth_stencil.bounds_test) |b| b.min else undefined,
            .max_depth_bounds = if (create_info.depth_stencil.bounds_test) |b| b.max else undefined,
        },
        .p_color_blend_state = &.{
            .attachment_count = @intCast(color_attachments.items.len),
            .p_attachments = color_attachments.items.ptr,
            .blend_constants = create_info.color_blend.blend_constants,
            .logic_op_enable = if (create_info.color_blend.logic_op != null) vk.TRUE else vk.FALSE,
            .logic_op = create_info.color_blend.logic_op orelse undefined,
        },
        .p_next = &vk.PipelineRenderingCreateInfo{
            .color_attachment_count = @intCast(create_info.target_info.color_attachments.len),
            .p_color_attachment_formats = create_info.target_info.color_attachments.ptr,
            .depth_attachment_format = create_info.target_info.depth_attachment orelse .undefined,
            .stencil_attachment_format = create_info.target_info.stencil_attachment orelse .undefined,
            .view_mask = create_info.target_info.view_mask,
        },
        .layout = create_info.layout,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    return if (try self.vkd.createGraphicsPipelines(
        self.device,
        .null_handle,
        1,
        util.meta.asConstArray(&vk_create_info),
        null,
        util.meta.asArray(&pipeline),
    ) != .success) error.createGraphicsPipelinesFailed else pipeline;
}

pub const ComputePipelineCreateInfo = struct {
    stage: vk.PipelineShaderStageCreateInfo,
    layout: vk.PipelineLayout,
};

pub fn createComputePipeline(self: *@This(), info: ComputePipelineCreateInfo) !vk.Pipeline {
    const vk_info = vk.ComputePipelineCreateInfo{
        .base_pipeline_index = 0,
        .stage = info.stage,
        .layout = info.layout,
    };

    var pipeline: vk.Pipeline = undefined;
    return if (try self.vkd.createComputePipelines(
        self.device,
        .null_handle,
        1,
        util.meta.asConstArray(&vk_info),
        null,
        util.meta.asArray(&pipeline),
    ) != .success) return error.createComputePipelineFailed else pipeline;
}

pub fn destroyPipeline(self: *@This(), pipeline: vk.Pipeline) void {
    self.vkd.destroyPipeline(self.device, pipeline, null);
}

pub fn allocateDescriptorSet(self: *@This(), dsl: vk.DescriptorSetLayout) !vk.DescriptorSet {
    var ds: vk.DescriptorSet = undefined;
    try self.vkd.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = util.meta.asConstArray(&dsl),
    }, util.meta.asArray(&ds));
    return ds;
}

pub fn freeDescriptorSet(self: *@This(), ds: vk.DescriptorSet) void {
    self.vkd.freeDescriptorSets(self.device, self.descriptor_pool, 1, util.meta.asConstArray(&ds)) catch unreachable;
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

fn findMemoryType(self: *@This(), type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const props = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);

    for (0..props.memory_type_count) |i| {
        const properties_match = vk.MemoryPropertyFlags.contains(props.memory_types[i].property_flags, properties);
        const type_match = type_filter & @as(u32, 1) << @intCast(i) != 0;

        if (type_match and properties_match) return @intCast(i);
    }

    return error.MemoryTypeNotFound;
}

pub const CreateBufferInfo = struct {
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    sharing_mode: vk.SharingMode = .exclusive,
    properties: vk.MemoryPropertyFlags,
};

pub fn createBuffer(self: *@This(), comptime T: type, info: CreateBufferInfo) !types.BufferVisible(T) {
    const size_in_bytes = info.size * @sizeOf(T);

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
    const ptr = try self.vkd.mapMemory(self.device, memory, 0, size_in_bytes, .{}) orelse return error.NullMemory;

    return types.BufferVisible(T){
        .handle = buffer,
        .requirements = memory_requirements,
        .memory = memory,
        .map = @as([*]T, @alignCast(@ptrCast(ptr)))[0..info.size],
    };
}

pub fn destroyBuffer(self: *@This(), typed_buffer: anytype) void {
    self.vkd.freeMemory(self.device, typed_buffer.memory, null);
    self.vkd.destroyBuffer(self.device, typed_buffer.handle, null);
}

pub const ImageDataCreateInfo = struct {
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
        .array_layers = info.array_layers,
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
        .subresource_range = builder.defaultSubrange(info.aspect_mask, info.array_layers),
        .components = builder.compIdentity,
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

pub const SamplerCreateInfo = struct {
    mag_filter: vk.Filter = .nearest,
    min_filter: vk.Filter = .nearest,
    mipmap: ?struct {
        mode: vk.SamplerMipmapMode,
        lod_bias: f32,
        lod_min: f32,
        lod_max: f32,
    } = null,
    address_mode: vk.SamplerAddressMode = .clamp_to_edge,
    anisotropy: ?f32 = null,
    compare_op: ?vk.CompareOp = null,
    border_color: vk.BorderColor = .int_transparent_black,
    unnormalized_coordinates: bool = false,
};

pub fn createSampler(self: *@This(), create_info: SamplerCreateInfo) !vk.Sampler {
    return try self.vkd.createSampler(self.device, &.{
        .mag_filter = create_info.mag_filter,
        .min_filter = create_info.min_filter,
        .address_mode_u = create_info.address_mode,
        .address_mode_v = create_info.address_mode,
        .address_mode_w = create_info.address_mode,
        .anisotropy_enable = if (create_info.anisotropy != null) vk.TRUE else vk.FALSE,
        .max_anisotropy = create_info.anisotropy orelse undefined,
        .border_color = create_info.border_color,
        .unnormalized_coordinates = if (create_info.unnormalized_coordinates) vk.TRUE else vk.FALSE,
        .compare_enable = if (create_info.compare_op != null) vk.TRUE else vk.FALSE,
        .compare_op = create_info.compare_op orelse undefined,
        .mipmap_mode = if (create_info.mipmap) |m| m.mode else .nearest,
        .mip_lod_bias = if (create_info.mipmap) |m| m.lod_bias else 0,
        .min_lod = if (create_info.mipmap) |m| m.lod_min else 0,
        .max_lod = if (create_info.mipmap) |m| m.lod_max else 0,
    }, null);
}

pub fn destroySampler(self: *@This(), sampler: vk.Sampler) void {
    self.vkd.destroySampler(self.device, sampler, null);
}

pub fn createCommandBuffer(self: *@This(), level: vk.CommandBufferLevel) !vk.CommandBuffer {
    var cmd_buf: vk.CommandBuffer = undefined;
    try self.vkd.allocateCommandBuffers(self.device, &.{
        .command_buffer_count = 1,
        .command_pool = self.graphic_command_pool,
        .level = level,
    }, util.meta.asArray(&cmd_buf));
    return cmd_buf;
}

pub fn destroyCommandBuffer(self: *@This(), cmd: vk.CommandBuffer) void {
    self.vkd.freeCommandBuffers(self.device, self.graphic_command_pool, 1, util.meta.asConstArray(&cmd));
}

pub const CommandBufferBeginInfo = struct {
    flags: vk.CommandBufferUsageFlags = .{},
    inheritance: ?*const vk.CommandBufferInheritanceInfo = null,
};

pub fn beginCommandBuffer(self: *@This(), cmd: vk.CommandBuffer, info: CommandBufferBeginInfo) !void {
    try self.vkd.beginCommandBuffer(cmd, &.{
        .flags = info.flags,
        .p_inheritance_info = info.inheritance,
    });
}

pub fn endCommandBuffer(self: *@This(), cmd: vk.CommandBuffer) !void {
    try self.vkd.endCommandBuffer(cmd);
}

pub fn resetCommandBuffer(
    self: *@This(),
    cmd: vk.CommandBuffer,
    flags: vk.CommandBufferResetFlags,
) !void {
    try self.vkd.resetCommandBuffer(cmd, flags);
}

pub fn cmdExecuteCommands(self: *@This(), cmd_primary: vk.CommandBuffer, cmds_secondary: []const vk.CommandBuffer) void {
    self.vkd.cmdExecuteCommands(cmd_primary, @intCast(cmds_secondary.len), cmds_secondary.ptr);
}

pub const DependencyInfo = struct {
    flags: vk.DependencyFlags = .{},
    memory_barriers: []const vk.MemoryBarrier2 = &.{},
    buffer_memory_barriers: []const vk.BufferMemoryBarrier2 = &.{},
    image_memory_barriers: []const vk.ImageMemoryBarrier2 = &.{},
};

pub fn cmdPipelineBarrier2(self: *@This(), cmd: vk.CommandBuffer, info: DependencyInfo) void {
    self.vkd.cmdPipelineBarrier2(cmd, &.{
        .dependency_flags = info.flags,
        .memory_barrier_count = @intCast(info.memory_barriers.len),
        .p_memory_barriers = info.memory_barriers.ptr,
        .buffer_memory_barrier_count = @intCast(info.buffer_memory_barriers.len),
        .p_buffer_memory_barriers = info.buffer_memory_barriers.ptr,
        .image_memory_barrier_count = @intCast(info.image_memory_barriers.len),
        .p_image_memory_barriers = info.image_memory_barriers.ptr,
    });
}

pub fn cmdBindPipeline(self: *@This(), cmd: vk.CommandBuffer, bind: vk.PipelineBindPoint, handle: vk.Pipeline) void {
    self.vkd.cmdBindPipeline(cmd, bind, handle);
}

pub fn cmdBindDescriptorSets(
    self: *@This(),
    cmd: vk.CommandBuffer,
    bind: vk.PipelineBindPoint,
    layout: vk.PipelineLayout,
    sets: struct { first: u32 = 0, slice: []const vk.DescriptorSet = &.{} },
    offsets: struct { slice: []const u32 = &.{} },
) void {
    self.vkd.cmdBindDescriptorSets(
        cmd,
        bind,
        layout,
        sets.first,
        @intCast(sets.slice.len),
        sets.slice.ptr,
        @intCast(offsets.slice.len),
        offsets.slice.ptr,
    );
}

pub fn cmdPushConstants(
    self: *@This(),
    cmd: vk.CommandBuffer,
    layout: vk.PipelineLayout,
    stage_flags: vk.ShaderStageFlags,
    data: anytype,
) void {
    self.vkd.cmdPushConstants(cmd, layout, stage_flags, 0, @sizeOf(@TypeOf(data)), &data);
}

pub fn cmdDraw(
    self: *@This(),
    cmd: vk.CommandBuffer,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void {
    self.vkd.cmdDraw(cmd, vertex_count, instance_count, first_vertex, first_instance);
}

pub fn cmdDispatch(
    self: *@This(),
    cmd: vk.CommandBuffer,
    group_count: @Vector(3, u32),
) void {
    self.vkd.cmdDispatch(cmd, group_count[0], group_count[1], group_count[2]);
}

pub fn cmdBeginRendering(self: *@This(), cmd: vk.CommandBuffer, rendering_info: vk.RenderingInfo) void {
    self.vkd.cmdBeginRendering(cmd, &rendering_info);
}

pub fn cmdEndRendering(self: *@This(), cmd: vk.CommandBuffer) void {
    self.vkd.cmdEndRendering(cmd);
}
