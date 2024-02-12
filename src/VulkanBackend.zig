const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const vk = @import("./vk.zig");
const types = @import("./vulkan_types.zig");
const initialization = @import("./vulkan_init.zig");

const zva = @import("./zva.zig");
const meta = @import("./meta.zig");

const stb = @cImport(@cInclude("stb/stb_image.h"));

const frame_data_count: u8 = 2;
const frame_max_draw_commands = 65536;
const frame_target_width = 400;
const frame_target_heigth = 300;

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

swapchain: types.SwapchainData,
frames: [frame_data_count]types.FrameData,
frame_index: @TypeOf(frame_data_count) = 2,

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

    try self.recreateSwapchain(.first_time);
    errdefer self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);

    try self.createFrameData();
    errdefer self.destroyFrameData();

    return self;
}

pub fn deinit(self: *@This()) void {
    self.destroyFrameData();

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

pub fn loop(self: *@This()) void {
    _ = self;
}

const RecreateSwapchainMode = enum { first_time, recreate };

pub fn recreateSwapchain(self: *@This(), comptime mode: RecreateSwapchainMode) !void {
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

fn formatHasStencil(format: vk.Format) bool {
    return format == .d16_unorm_s8_uint or
        format == .d24_unorm_s8_uint or
        format == .d32_sfloat_s8_uint;
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
};

fn createImage(self: *@This(), info: ImageDataCreateInfo) !types.ImageData {
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

    try self.vkd.bindImageMemory(self.device, image, memory, 0);

    const view = try self.vkd.createImageView(self.device, &.{
        .image = image,
        .view_type = if (info.array_layers > 1) .@"2d" else .@"2d_array",
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
    };
}

fn destroyImage(self: *@This(), image_data: types.ImageData) void {
    self.vkd.destroyImageView(self.device, image_data.view, null);
    self.vkd.freeMemory(self.device, image_data.memory, null);
    self.vkd.destroyImage(self.device, image_data.handle, null);
}

fn createFrameData(self: *@This()) !void {
    self.frames = .{ .{}, .{} };
    errdefer self.destroyFrameData();

    const image_extent = vk.Extent2D{ .width = frame_target_width, .height = frame_target_heigth };

    const aspect_depth_stencil = vk.ImageAspectFlags{ .depth_bit = true, .stencil_bit = true };
    const aspect_depth = vk.ImageAspectFlags{ .depth_bit = true };

    const depth_format = try self.findDepthImageFormat();
    const depth_aspect = if (formatHasStencil(depth_format)) aspect_depth_stencil else aspect_depth;

    for (self.frames[0..]) |*frame| {
        frame.draw_buffer = try self.createBuffer(types.DrawData, .{
            .size = frame_max_draw_commands,
            .usage = .{ .storage_buffer_bit = true },
            .properties = .{ .host_visible_bit = true },
        });

        frame.image_color = try self.createImage(.{
            .extent = image_extent,
            .format = .r16g16b16a16_sfloat,
            .usage = .{ .color_attachment_bit = true, .sampled_bit = true },
            .property = .{ .device_local_bit = true },
            .aspect_mask = .{ .color_bit = true },
        });

        frame.image_depth = try self.createImage(.{
            .extent = image_extent,
            .format = depth_format,
            .usage = .{ .depth_stencil_attachment_bit = true },
            .property = .{ .device_local_bit = true },
            .aspect_mask = depth_aspect,
        });

        frame.fence_busy = try self.vkd.createFence(self.device, &.{ .flags = .{ .signaled_bit = true } }, null);
        frame.semaphore_opaque_render_finished = try self.vkd.createSemaphore(self.device, &.{}, null);
        frame.semaphore_blend_render_finished = try self.vkd.createSemaphore(self.device, &.{}, null);
        frame.semaphore_ui_render_finished = try self.vkd.createSemaphore(self.device, &.{}, null);
        frame.semaphore_present_render_finished = try self.vkd.createSemaphore(self.device, &.{}, null);

        // TODO create descriptor set
    }
}

fn destroyFrameData(self: *@This()) void {
    for (self.frames[0..]) |frame| {
        if (frame.draw_buffer.handle != .null_handle) self.destroyBuffer(frame.draw_buffer);
        if (frame.image_color.handle != .null_handle) self.destroyImage(frame.image_color);
        if (frame.image_depth.handle != .null_handle) self.destroyImage(frame.image_depth);
        if (frame.fence_busy != .null_handle) self.vkd.destroyFence(self.device, frame.fence_busy, null);

        if (frame.semaphore_opaque_render_finished != .null_handle) {
            self.vkd.destroySemaphore(self.device, frame.semaphore_opaque_render_finished, null);
        }

        if (frame.semaphore_blend_render_finished != .null_handle) {
            self.vkd.destroySemaphore(self.device, frame.semaphore_blend_render_finished, null);
        }

        if (frame.semaphore_ui_render_finished != .null_handle) {
            self.vkd.destroySemaphore(self.device, frame.semaphore_ui_render_finished, null);
        }

        if (frame.semaphore_present_render_finished != .null_handle) {
            self.vkd.destroySemaphore(self.device, frame.semaphore_present_render_finished, null);
        }

        // TODO destroy descriptor set
    }
}
