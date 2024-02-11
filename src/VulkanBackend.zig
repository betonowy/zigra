const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const vk = @import("./vk.zig");
const types = @import("./vulkan_types.zig");
const initialization = @import("./vulkan_init.zig");

const zva = @import("./zva.zig");
const meta = @import("./meta.zig");

const stb = @cImport(@cInclude("stb/stb_image.h"));

const frame_data_count = 2;

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
frame: [frame_data_count]types.FrameData,
frame_index: u8,

pub fn init(
    allocator: std.mem.Allocator,
    get_proc_addr: vk.PfnGetInstanceProcAddr,
    window_callbacks: *const types.WindowCallbacks,
) !*@This() {
    var self = try allocator.create(@This());
    errdefer allocator.destroy(self);

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

    self.frame_index = 0;

    return self;
}

pub fn deinit(self: *@This()) void {
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
    self.allocator.destroy(self);
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
