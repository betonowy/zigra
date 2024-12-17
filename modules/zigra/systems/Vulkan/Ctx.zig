const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vk");

const utils = @import("util");

const VkAllocator = @import("Ctx/VkAllocator.zig");
const types = @import("Ctx/types.zig");
const initialization = @import("Ctx/init.zig");
const builder = @import("Ctx/builder.zig");

const log = std.log.scoped(.Vulkan_Ctx);

allocator: std.mem.Allocator,

vka: VkAllocator,
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
        .max_sets = 2,
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
    errdefer self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);

    return self;
}

pub fn deinit(self: *@This()) void {
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
