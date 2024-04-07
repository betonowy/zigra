const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const vk = @import("./vk.zig");
const types = @import("./vulkan_types.zig");
const initialization = @import("./vulkan_init.zig");
const builder = @import("./vulkan_builder.zig");
const meta = @import("./meta.zig");
const Atlas = @import("VulkanAtlas.zig");
const Landscape = @import("VulkanLandscape.zig");
const LandSim = @import("./LandscapeSim.zig");
const spv = @import("shaders/spv.zig");

const stb = @cImport(@cInclude("stb/stb_image.h"));

pub const frame_data_count: u8 = 2;
pub const frame_max_draw_commands = 65536;
pub const frame_target_width = 320;
pub const frame_target_height = 200;
pub const frame_format = vk.Format.r16g16b16a16_sfloat;

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
frames: [frame_data_count]FrameData,
frame_index: @TypeOf(frame_data_count) = 0,
pipelines: types.Pipelines,
atlas: Atlas,

camera_pos: @Vector(2, i32),
start_timestamp: i128,

upload_line_data: std.ArrayListUnmanaged(types.LineData),

pub const FrameData = struct {
    fence_busy: vk.Fence = .null_handle,
    semaphore_swapchain_image_acquired: vk.Semaphore = .null_handle,
    semaphore_finished: vk.Semaphore = .null_handle,

    image_color_sampler: vk.Sampler = .null_handle,
    image_color: types.ImageData = .{},
    image_depth: types.ImageData = .{},

    landscape: Landscape = .{},
    landscape_upload: Landscape.UploadSets = .{},

    descriptor_set: vk.DescriptorSet = .null_handle,

    draw_buffer: types.BufferVisible(types.DrawData) = .{},
    draw_sprite_opaque_index: u32 = 0,
    draw_sprite_opaque_range: u32 = 0,
    draw_landscape_index: u32 = 0,
    draw_landscape_range: u32 = 0,
    draw_line_index: u32 = 0,
    draw_line_range: u32 = 0,

    command_buffer: vk.CommandBuffer = .null_handle,
};

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
    errdefer self.destroySwapchain();

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

    self.start_timestamp = std.time.nanoTimestamp();
    self.camera_pos = .{ 0, 0 };

    self.upload_line_data = .{};

    return self;
}

pub fn deinit(self: *@This()) void {
    self.upload_line_data.deinit(self.allocator);

    self.vkd.deviceWaitIdle(self.device) catch unreachable;

    self.atlas.deinit(self);
    self.destroyFrameData();
    self.destroyCommandPools();
    self.destroyPipelines();
    self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    self.destroySwapchain();
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

    const landscape_u_dur: f32 = @floatFromInt(timer.lap());
    _ = landscape_u_dur; // autofix

    if (try self.vkd.waitForFences(
        self.device,
        1,
        meta.asConstArray(&self.frames[self.frame_index].fence_busy),
        vk.TRUE,
        1_000_000_000,
    ) != .success) return error.FenceTimeout;

    const fence_dur: f32 = @floatFromInt(timer.lap());
    _ = fence_dur; // autofix

    try self.vkd.resetCommandBuffer(self.frames[self.frame_index].command_buffer, .{});
    try self.vkd.beginCommandBuffer(self.frames[self.frame_index].command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    try self.frames[self.frame_index].landscape.recordUploadData(self, self.frames[self.frame_index].command_buffer, self.frames[self.frame_index].landscape_upload);

    const landscape_r_dur: f32 = @floatFromInt(timer.lap());
    _ = landscape_r_dur; // autofix

    try self.uploadScheduledData(&self.frames[self.frame_index]);

    const upload_dur: f32 = @floatFromInt(timer.lap());
    _ = upload_dur; // autofix

    const next_image = try self.acquireNextSwapchainImage();

    if (next_image.result == .error_out_of_date_khr) {
        try self.createSwapchain(.recreate);
        return;
    }

    const acquire_dur: f32 = @floatFromInt(timer.lap());
    _ = acquire_dur; // autofix

    try self.recordDrawFrame(
        self.frames[self.frame_index],
        next_image.image_index,
    );

    try self.vkd.endCommandBuffer(self.frames[self.frame_index].command_buffer);

    var wait_semaphores = std.BoundedArray(vk.Semaphore, 4).init(0) catch unreachable;
    var wait_dst_stage_mask = std.BoundedArray(vk.PipelineStageFlags, 4).init(0) catch unreachable;

    try wait_semaphores.append(self.frames[self.frame_index].semaphore_swapchain_image_acquired);
    try wait_dst_stage_mask.append(.{ .color_attachment_output_bit = true });

    std.debug.assert(wait_semaphores.len == wait_dst_stage_mask.len);

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = wait_semaphores.len,
        .p_wait_semaphores = wait_semaphores.constSlice().ptr,
        .p_wait_dst_stage_mask = wait_dst_stage_mask.constSlice().ptr,
        .command_buffer_count = 1,
        .p_command_buffers = meta.asConstArray(&self.frames[self.frame_index].command_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = meta.asConstArray(&self.frames[self.frame_index].semaphore_finished),
    };

    try self.vkd.resetFences(self.device, 1, meta.asConstArray(&self.frames[self.frame_index].fence_busy));
    try self.vkd.queueSubmit(self.graphic_queue, 1, meta.asConstArray(&submit_info), self.frames[self.frame_index].fence_busy);

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

    // std.debug.print(
    //     \\ --------------------
    //     \\ lu:    {d: >6.3} ms
    //     \\ fence: {d: >6.3} ms
    //     \\ lr:    {d: >6.3} ms
    //     \\ up:    {d: >6.3} ms
    //     \\ acq:   {d: >6.3} ms
    //     \\ draw:  {d: >6.3} ms
    //     \\ p:     {d: >6.3} ms
    //     \\ total: {d: >6.3} ms
    //     \\ nofen: {d: >6.3} ms
    //     \\
    // , .{
    //     landscape_u_dur * to_ms,
    //     fence_dur * to_ms,
    //     landscape_r_dur * to_ms,
    //     upload_dur * to_ms,
    //     acquire_dur * to_ms,
    //     draw_dur * to_ms,
    //     present_dur * to_ms,
    //     (landscape_u_dur + fence_dur + landscape_r_dur + upload_dur + acquire_dur + draw_dur + present_dur) * to_ms,
    //     (landscape_u_dur + landscape_r_dur + upload_dur + acquire_dur + draw_dur + present_dur) * to_ms,
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
            .components = builder.compIdentity,
            .subresource_range = builder.defaultSubrange(.{ .color_bit = true }, 1),
        }, null);
    }
}

pub fn destroySwapchain(self: *@This()) void {
    for (self.swapchain.views.slice()) |view| {
        self.vkd.destroyImageView(self.device, view, null);
    }

    self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);
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

fn createDescriptorPool(self: *@This()) !vk.DescriptorPool {
    return try self.vkd.createDescriptorPool(self.device, &.{
        .pool_size_count = builder.pipeline.descriptor_pool_sizes.len,
        .p_pool_sizes = &builder.pipeline.descriptor_pool_sizes,
        .max_sets = 2,
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
}

fn createShaderModule(self: *@This(), byte_code: []const u32) !vk.ShaderModule {
    return try self.vkd.createShaderModule(self.device, &.{
        .code_size = byte_code.len * @sizeOf(std.meta.Child(@TypeOf(byte_code))),
        .p_code = @alignCast(@ptrCast(byte_code)),
    }, null);
}

fn createPipelines(self: *@This()) !void {
    const sprite_vs = try self.createShaderModule(&spv.sprite_vert);
    defer self.vkd.destroyShaderModule(self.device, sprite_vs, null);
    const sprite_opaque_fs = try self.createShaderModule(&spv.sprite_opaque_frag);
    defer self.vkd.destroyShaderModule(self.device, sprite_opaque_fs, null);
    const fullscreen_vs = try self.createShaderModule(&spv.fullscreen_vert);
    defer self.vkd.destroyShaderModule(self.device, fullscreen_vs, null);
    const present_fs = try self.createShaderModule(&spv.final_frag);
    defer self.vkd.destroyShaderModule(self.device, present_fs, null);
    const landscape_vs = try self.createShaderModule(&spv.landscape_vert);
    defer self.vkd.destroyShaderModule(self.device, landscape_vs, null);
    const landscape_fs = try self.createShaderModule(&spv.landscape_frag);
    defer self.vkd.destroyShaderModule(self.device, landscape_fs, null);
    const line_vs = try self.createShaderModule(&spv.line_vert);
    defer self.vkd.destroyShaderModule(self.device, line_vs, null);
    const line_opaque_fs = try self.createShaderModule(&spv.line_opaque_frag);
    defer self.vkd.destroyShaderModule(self.device, line_opaque_fs, null);

    self.pipelines.resolved_depth_format = try self.findDepthImageFormat();
    self.pipelines.resolved_depth_aspect = builder.depthImageAspect(self.pipelines.resolved_depth_format);
    self.pipelines.resolved_depth_layout = builder.depthImageLayout(self.pipelines.resolved_depth_format);

    const line_opaque_stage_create_info = builder.pipeline.shader_stage.vsFs(line_vs, line_opaque_fs, .{});
    const landscape_stage_create_info = builder.pipeline.shader_stage.vsFs(landscape_vs, landscape_fs, .{});
    const sprite_opaque_stage_create_info = builder.pipeline.shader_stage.vsFs(sprite_vs, sprite_opaque_fs, .{});
    const present_shader_stage_create_info = builder.pipeline.shader_stage.vsFs(fullscreen_vs, present_fs, .{});
    const dynamic_state_create_info = builder.pipeline.dynamicState(.minimal);
    const triangle_assembly_stage_create_info = builder.pipeline.assemblyState(.triangle_strip);
    const line_assembly_stage_create_info = builder.pipeline.assemblyState(.line_list);

    self.pipelines.descriptor_set_layout = try self.vkd.createDescriptorSetLayout(self.device, &.{
        .binding_count = builder.pipeline.dslb_bindings.len,
        .p_bindings = &builder.pipeline.dslb_bindings,
    }, null);
    errdefer self.vkd.destroyDescriptorSetLayout(self.device, self.pipelines.descriptor_set_layout, null);

    const push_constant = builder.pipeline.pushConstantVsFs(@sizeOf(types.BasicPushConstant));

    self.pipelines.pipeline_line.layout = try self.vkd.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = meta.asConstArray(&push_constant),
    }, null);
    errdefer self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_line.layout, null);

    self.pipelines.pipeline_landscape.layout = try self.vkd.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = meta.asConstArray(&push_constant),
    }, null);
    errdefer self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_landscape.layout, null);

    self.pipelines.pipeline_sprite_opaque.layout = try self.vkd.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = meta.asConstArray(&push_constant),
    }, null);
    errdefer self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_sprite_opaque.layout, null);

    self.pipelines.pipeline_present.layout = try self.vkd.createPipelineLayout(self.device, &.{
        .set_layout_count = 1,
        .p_set_layouts = meta.asConstArray(&self.pipelines.descriptor_set_layout),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    errdefer self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_present.layout, null);

    const target_render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = meta.asConstArray(&frame_format),
        .depth_attachment_format = self.pipelines.resolved_depth_format,
        .view_mask = 0,
        .stencil_attachment_format = .undefined,
    };

    const present_render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = meta.asConstArray(&self.swapchain.format),
        .depth_attachment_format = .undefined,
        .view_mask = 0,
        .stencil_attachment_format = .undefined,
    };

    const pipeline_line_opaque_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_dynamic_state = &dynamic_state_create_info,
        .p_stages = &line_opaque_stage_create_info,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &line_assembly_stage_create_info,
        .p_viewport_state = &builder.pipeline.dummy_viewport_state,
        .p_rasterization_state = &builder.pipeline.default_rasterization,
        .p_multisample_state = &builder.pipeline.disabled_multisampling,
        .p_depth_stencil_state = &builder.pipeline.enabled_depth_attachment,
        .p_color_blend_state = &builder.pipeline.disabled_color_blending,
        .layout = self.pipelines.pipeline_line.layout,
        .p_next = &target_render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    const pipeline_landscape_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_dynamic_state = &dynamic_state_create_info,
        .p_stages = &landscape_stage_create_info,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &triangle_assembly_stage_create_info,
        .p_viewport_state = &builder.pipeline.dummy_viewport_state,
        .p_rasterization_state = &builder.pipeline.default_rasterization,
        .p_multisample_state = &builder.pipeline.disabled_multisampling,
        .p_depth_stencil_state = &builder.pipeline.enabled_depth_attachment,
        .p_color_blend_state = &builder.pipeline.disabled_color_blending,
        .layout = self.pipelines.pipeline_landscape.layout,
        .p_next = &target_render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    const pipeline_sprite_opaque_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_dynamic_state = &dynamic_state_create_info,
        .p_stages = &sprite_opaque_stage_create_info,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &triangle_assembly_stage_create_info,
        .p_viewport_state = &builder.pipeline.dummy_viewport_state,
        .p_rasterization_state = &builder.pipeline.default_rasterization,
        .p_multisample_state = &builder.pipeline.disabled_multisampling,
        .p_depth_stencil_state = &builder.pipeline.enabled_depth_attachment,
        .p_color_blend_state = &builder.pipeline.disabled_color_blending,
        .layout = self.pipelines.pipeline_sprite_opaque.layout,
        .p_next = &target_render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    const pipeline_present_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_dynamic_state = &dynamic_state_create_info,
        .p_stages = &present_shader_stage_create_info,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &triangle_assembly_stage_create_info,
        .p_viewport_state = &builder.pipeline.dummy_viewport_state,
        .p_rasterization_state = &builder.pipeline.default_rasterization,
        .p_multisample_state = &builder.pipeline.disabled_multisampling,
        .p_depth_stencil_state = &builder.pipeline.disabled_depth_attachment,
        .p_color_blend_state = &builder.pipeline.disabled_color_blending,
        .layout = self.pipelines.pipeline_present.layout,
        .p_next = &present_render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    if (try self.vkd.createGraphicsPipelines(
        self.device,
        .null_handle,
        1,
        meta.asConstArray(&pipeline_line_opaque_info),
        null,
        meta.asArray(&self.pipelines.pipeline_line.handle),
    ) != .success) return error.InitializationFailed;
    errdefer self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_line.handle, null);

    if (try self.vkd.createGraphicsPipelines(
        self.device,
        .null_handle,
        1,
        meta.asConstArray(&pipeline_landscape_info),
        null,
        meta.asArray(&self.pipelines.pipeline_landscape.handle),
    ) != .success) return error.InitializationFailed;
    errdefer self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_landscape.handle, null);

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
    self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_landscape.handle, null);
    self.vkd.destroyPipeline(self.device, self.pipelines.pipeline_line.handle, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_present.layout, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_sprite_opaque.layout, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_landscape.layout, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipelines.pipeline_line.layout, null);
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

    const image_extent = vk.Extent2D{ .width = frame_target_width, .height = frame_target_height };

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

        frame.landscape = try Landscape.init(self);
        frame.landscape_upload.resize(0) catch unreachable;

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
            .range = std.mem.sliceAsBytes(frame.draw_buffer.map).len,
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

        var ds_landscape_info: [Landscape.tile_count]vk.DescriptorImageInfo = undefined;

        for (ds_landscape_info[0..], frame.landscape.tiles[0..]) |*info, tile| {
            info.image_layout = .shader_read_only_optimal;
            info.image_view = tile.device_image.view;
            info.sampler = tile.sampler;
        }

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

        const write_landscape = vk.WriteDescriptorSet{
            .descriptor_count = ds_landscape_info.len,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 3,
            .dst_set = frame.descriptor_set,
            .p_image_info = &ds_landscape_info,
        };

        const writes = [_]vk.WriteDescriptorSet{ write_ssb, write_atlas, write_img, write_landscape };

        self.vkd.updateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }
}

fn destroyFrameData(self: *@This()) void {
    for (self.frames[0..]) |*frame| {
        if (frame.command_buffer != .null_handle) {
            self.vkd.freeCommandBuffers(
                self.device,
                self.graphic_command_pool,
                1,
                meta.asConstArray(&frame.command_buffer),
            );
        }

        frame.landscape.deinit(self);

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
                return .{ .result = .error_out_of_date_khr, .image_index = 0 };
            },
            else => return err,
        }
    };

    return next_image_result;
}

fn presentSwapchainImage(self: *@This(), frame: FrameData, swapchain_image_index: u32) !vk.Result {
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

fn recordDrawFrame(self: *@This(), frame: FrameData, swapchain_image_index: u32) !void {
    self.transitionFrameImagesBegin(frame);
    self.beginRenderingOpaque(frame);

    const push = types.BasicPushConstant{
        .atlas_size = .{
            self.atlas.image.extent.width,
            self.atlas.image.extent.height,
        },
        .target_size = .{
            frame.image_color.extent.width,
            frame.image_color.extent.height,
        },
        .camera_pos = self.camera_pos,
    };

    {
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

        self.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.pipeline_sprite_opaque.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.vkd.cmdDraw(
            frame.command_buffer,
            4,
            frame.draw_sprite_opaque_range,
            0,
            frame.draw_sprite_opaque_index,
        );
    }
    {
        self.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.pipeline_line.handle);

        self.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.pipeline_line.layout,
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

        self.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.pipeline_line.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.vkd.cmdDraw(
            frame.command_buffer,
            2,
            frame.draw_line_range,
            0,
            frame.draw_line_index,
        );
    }
    {
        self.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.pipeline_landscape.handle);

        self.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.pipeline_landscape.layout,
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

        self.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.pipeline_sprite_opaque.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.vkd.cmdDraw(frame.command_buffer, 4, frame.draw_landscape_range, 0, frame.draw_landscape_index);
    }

    self.vkd.cmdEndRendering(frame.command_buffer);
    self.transitionFrameImagesFinal(frame, swapchain_image_index);
    self.beginRenderingFinal(frame, swapchain_image_index);
    self.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.pipeline_present.handle);

    self.vkd.cmdBindDescriptorSets(
        frame.command_buffer,
        .graphics,
        self.pipelines.pipeline_present.layout,
        0,
        1,
        meta.asConstArray(&frame.descriptor_set),
        0,
        null,
    );

    const integer_scaling = integerScaling(self.swapchain.extent, frame.image_color.extent);

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
}

fn transitionFrameImagesBegin(self: *@This(), frame: FrameData) void {
    const depth_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .fragment_shader_bit = true },
        .src_access_mask = .{ .memory_read_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true },
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
        .src_stage_mask = .{ .bottom_of_pipe_bit = true },
        .src_access_mask = .{ .memory_read_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_write_bit = true },
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

fn beginRenderingOpaque(self: *@This(), frame: FrameData) void {
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

fn transitionFrameImagesFinal(self: *@This(), frame: FrameData, swapchain_image_index: u32) void {
    const swapchain_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .bottom_of_pipe_bit = true },
        .src_access_mask = .{ .memory_read_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_write_bit = true },
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
        .src_stage_mask = .{ .fragment_shader_bit = true },
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
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

fn beginRenderingFinal(self: *@This(), frame: FrameData, swapchain_image_index: u32) void {
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

fn transitionFrameImagesPresent(self: *@This(), frame: FrameData, swapchain_image_index: u32) void {
    const swapchain_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_read_bit = true },
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

pub fn scheduleLine(self: *@This(), points: [2]@Vector(2, f32), color: @Vector(4, f16), depth: f32, alpha: @Vector(2, f16)) !void {
    try self.upload_line_data.append(self.allocator, .{
        .points = points,
        .color = color,
        .depth = depth,
        .alpha_gradient = alpha,
    });
}

fn uploadScheduledData(self: *@This(), frame: *FrameData) !void {
    var current_index: u32 = 0;

    for (
        self.frames[self.frame_index].landscape.active_sets.constSlice(),
        frame.draw_buffer.map[current_index .. current_index + self.frames[self.frame_index].landscape.active_sets.len],
    ) |set, *cmd| {
        cmd.landscape = .{
            .depth = 0.9,
            .descriptor = @intCast(set.tile.table_index),
            .offset = set.tile.coord,
            .size = .{ Landscape.image_size, Landscape.image_size },
        };
    }

    frame.draw_landscape_index = current_index;
    frame.draw_landscape_range = self.frames[self.frame_index].landscape.active_sets.len;
    current_index += self.frames[self.frame_index].landscape.active_sets.len;

    var prng = std.rand.DefaultPrng.init(@intCast(std.time.nanoTimestamp() & 0xffffffffffffffff));
    var position: [5]@Vector(2, f32) = undefined;
    const point: [5]@Vector(2, f32) = .{
        .{ -40, -80 },
        .{ -20, -60 },
        .{ -30, -53 },
        .{ -25, -46 },
        .{ -10, -30 },
    };

    for (position[0..]) |*pos| pos.* = .{
        prng.random().floatNorm(f32),
        prng.random().floatNorm(f32),
    };

    const lines_count = 4;

    for (frame.draw_buffer.map[current_index .. current_index + lines_count], 0..) |*cmd, i| {
        cmd.line = .{
            .color = .{ 0.7, 0.8, 1.0, 1.0 },
            .alpha_gradient = .{ 1.0, 1.0 },
            .depth = 0.5,
            .points = .{
                position[i + 0] + point[i + 0],
                position[i + 1] + point[i + 1],
            },
        };
    }

    // Upload scheduled lines
    frame.draw_line_index = current_index;
    frame.draw_line_range = @intCast(self.upload_line_data.items.len);

    {
        const begin = current_index;
        const end = begin + self.upload_line_data.items.len;

        for (self.upload_line_data.items, frame.draw_buffer.map[begin..end]) |src, *dst| dst.line = src;

        current_index += @intCast(self.upload_line_data.items.len);
        self.upload_line_data.clearRetainingCapacity();
    }
}

fn floatToSnorm16(value: f32, comptime range: f32) i16 {
    return @max(-std.math.maxInt(i16), @as(i16, @intFromFloat(value * (1.0 / range) * std.math.maxInt(i16))));
}

fn snorm16ToFloat(value: i16, comptime range: f32) f32 {
    return @as(f32, @floatFromInt(@max(-std.math.maxInt(i16), value))) * (1.0 / std.math.maxInt(i16)) * range;
}

fn floatToUnorm16(value: f32, comptime range: f32) u16 {
    return @intFromFloat(value * std.math.maxInt(u16) * (1.0 / range));
}

fn unorm16ToFloat(value: u16, comptime range: f32) f32 {
    return range * @as(f32, @floatFromInt(value)) / (1.0 / std.math.maxInt(u16));
}
