const vk = @import("./vk.zig");
const types = @import("./vulkan_types.zig");
const std = @import("std");
const builtin = @import("builtin");
const meta = @import("./meta.zig");

fn vulkanDebugCallback(
    _: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (p_callback_data) |data| {
        if (data.p_message) |message| {
            std.debug.print("Vulkan validation layer: {s}\n", .{message});
        }
    }

    return vk.FALSE;
}

pub fn createDebugMessenger(vki: types.InstanceDispatch, vk_instance: vk.Instance) !?vk.DebugUtilsMessengerEXT {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return null;

    return try vki.createDebugUtilsMessengerEXT(vk_instance, &.{
        .message_severity = .{
            .error_bit_ext = true,
            .warning_bit_ext = true,
            .info_bit_ext = true,
            .verbose_bit_ext = true,
        },
        .message_type = .{
            .validation_bit_ext = true,
            .performance_bit_ext = true,
            .general_bit_ext = true,
            .device_address_binding_bit_ext = false,
        },
        .pfn_user_callback = vulkanDebugCallback,
    }, null);
}

const expected_debug_layers = if (builtin.mode == .Debug) [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
} else [_][*:0]const u8{};

pub fn createVulkanInstance(
    vkb: types.BaseDispatch,
    allocator: std.mem.Allocator,
    window_callbacks: *const types.WindowCallbacks,
) !vk.Instance {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const glfw_extensions = try window_callbacks.getRequiredInstanceExtensions();

    var extensions = std.ArrayList([*:0]const u8).init(arena_allocator);
    try extensions.appendSlice(glfw_extensions);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        var layer_count: u32 = undefined;

        if (try vkb.enumerateInstanceLayerProperties(&layer_count, null) != .success) {
            @panic("Cannot get number of vulkan layers");
        }

        var reported_layers = try std.ArrayList(vk.LayerProperties).initCapacity(arena_allocator, layer_count);
        try reported_layers.resize(layer_count);

        std.debug.assert(reported_layers.items.len == layer_count);

        if (try vkb.enumerateInstanceLayerProperties(&layer_count, reported_layers.items.ptr) != .success) {
            @panic("Cannot enumerate vulkan layers");
        }

        var all_found = true;

        for (expected_debug_layers) |expected_layer| {
            var checked = false;

            for (reported_layers.items) |reported_layer| {
                if (std.mem.orderZ(u8, @as([*:0]const u8, @ptrCast(&reported_layer.layer_name)), expected_layer) == .eq) {
                    checked = true;
                    break;
                }
            }

            if (!checked) {
                all_found = false;
                break;
            }
        }

        if (!all_found) {
            @panic("Requested vulkan layers not available");
        }

        try extensions.append("VK_EXT_debug_utils");
    }

    return try vkb.createInstance(&.{
        .enabled_extension_count = @intCast(extensions.items.len),
        .pp_enabled_extension_names = extensions.items.ptr,
        .p_application_info = &.{
            .p_application_name = "Zigra",
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        },
        .enabled_layer_count = @intCast(expected_debug_layers.len),
        .pp_enabled_layer_names = &expected_debug_layers,
    }, null);
}

pub fn pickPhysicalDevice(
    vki: types.InstanceDispatch,
    vk_instance: vk.Instance,
    vk_surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.PhysicalDevice {
    var device_count: u32 = undefined;

    if (try vki.enumeratePhysicalDevices(vk_instance, &device_count, null) != .success or device_count == 0) {
        @panic("Failed to find vulkan compatible devices");
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const devices = try arena_allocator.alloc(vk.PhysicalDevice, device_count);

    if (try vki.enumeratePhysicalDevices(vk_instance, &device_count, devices.ptr) != .success) unreachable;

    for (devices) |device| {
        if (try isDeviceSuitable(vki, device, vk_surface, arena_allocator)) return device;
    }

    return error.InitializationFailed;
}

fn isDeviceSuitable(
    vki: types.InstanceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    vk_surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !bool {
    _ = findQueueFamilies(vki, vk_physical_device, vk_surface, allocator) catch return false;

    if (!try checkExtensionSupport(vki, vk_physical_device, allocator)) return false;

    const swap_chain_support_details = try querySwapChainSupport(vki, vk_physical_device, vk_surface, allocator);
    defer swap_chain_support_details.deinit();

    if (swap_chain_support_details.formats.?.len == 0) return false;
    if (swap_chain_support_details.present_modes.?.len == 0) return false;

    return true;
}

const required_device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
};

fn checkExtensionSupport(
    vki: types.InstanceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
) !bool {
    var extension_count: u32 = undefined;
    if (try vki.enumerateDeviceExtensionProperties(vk_physical_device, null, &extension_count, null) != .success) unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const extension_properties = try arena.allocator().alloc(vk.ExtensionProperties, extension_count);
    if (try vki.enumerateDeviceExtensionProperties(
        vk_physical_device,
        null,
        &extension_count,
        extension_properties.ptr,
    ) != .success) unreachable;

    var all_available = true;

    for (required_device_extensions) |required_extension| {
        var checked = false;

        for (extension_properties) |property| {
            if (std.mem.orderZ(u8, required_extension, @ptrCast(&property.extension_name)) == .eq) {
                checked = true;
                break;
            }
        }

        if (!checked) {
            all_available = false;
            break;
        }
    }

    return all_available;
}

pub fn findQueueFamilies(
    vki: types.InstanceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    vk_surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !types.QueueFamilyIndicesComplete {
    var indices = types.QueueFamilyIndicesIncomplete{};
    var index_count: u32 = undefined;

    vki.getPhysicalDeviceQueueFamilyProperties(vk_physical_device, &index_count, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const queue_families = try arena_allocator.alloc(vk.QueueFamilyProperties, index_count);

    vki.getPhysicalDeviceQueueFamilyProperties(vk_physical_device, &index_count, queue_families.ptr);

    for (queue_families, 0..) |queue_family, i| {
        if (indices.graphicsFamily == null and queue_family.queue_flags.graphics_bit) {
            indices.graphicsFamily = @intCast(i);
        }

        if (indices.presentFamily == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(
            vk_physical_device,
            @intCast(i),
            vk_surface,
        )) == vk.TRUE) {
            indices.presentFamily = @intCast(i);
        }

        if (indices.isComplete()) return indices.complete();
    }

    return error.Incomplete;
}

pub fn querySwapChainSupport(
    vki: types.InstanceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    vk_surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !SwapChainSupportDetails {
    var details = SwapChainSupportDetails.init(allocator);
    errdefer details.deinit();

    details.capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(vk_physical_device, vk_surface);

    var format_count: u32 = undefined;

    if (try vki.getPhysicalDeviceSurfaceFormatsKHR(vk_physical_device, vk_surface, &format_count, null) != .success) {
        return error.InitializationFailed;
    }

    if (format_count > 0) {
        const formats = try details.allocator.alloc(vk.SurfaceFormatKHR, format_count);

        if (try vki.getPhysicalDeviceSurfaceFormatsKHR(
            vk_physical_device,
            vk_surface,
            &format_count,
            formats.ptr,
        ) != .success) {
            return error.InitializationFailed;
        }

        details.formats = formats;
    }

    var present_mode_count: u32 = undefined;

    if (try vki.getPhysicalDeviceSurfacePresentModesKHR(
        vk_physical_device,
        vk_surface,
        &present_mode_count,
        null,
    ) != .success) {
        return error.InitializationFailed;
    }

    if (present_mode_count > 0) {
        const present_modes = try details.allocator.alloc(vk.PresentModeKHR, present_mode_count);

        if (try vki.getPhysicalDeviceSurfacePresentModesKHR(
            vk_physical_device,
            vk_surface,
            &present_mode_count,
            present_modes.ptr,
        ) != .success) {
            return error.InitializationFailed;
        }

        details.present_modes = present_modes;
    }

    return details;
}

pub fn createLogicalDevice(
    vki: types.InstanceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    queue_family_indices: types.QueueFamilyIndicesComplete,
) !vk.Device {
    const priority = [_]f32{1.0};

    const queue_create_infos = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = queue_family_indices.graphicsFamily,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = queue_family_indices.presentFamily,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const synchronization_2 = vk.PhysicalDeviceSynchronization2Features{
        .synchronization_2 = vk.TRUE,
    };

    const dynamic_rendering_feature = vk.PhysicalDeviceDynamicRenderingFeatures{
        .dynamic_rendering = vk.TRUE,
        .p_next = @constCast(&synchronization_2),
    };

    return try vki.createDevice(vk_physical_device, &.{
        .p_queue_create_infos = &queue_create_infos,
        .queue_create_info_count = 1,
        .p_enabled_features = &.{ .sampler_anisotropy = vk.TRUE },
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = &required_device_extensions,
        .enabled_layer_count = expected_debug_layers.len,
        .pp_enabled_layer_names = &expected_debug_layers,
        .p_next = &dynamic_rendering_feature,
    }, null);
}

const SwapChainSupportDetails = struct {
    allocator: std.mem.Allocator,
    capabilities: ?vk.SurfaceCapabilitiesKHR = null,
    formats: ?[]vk.SurfaceFormatKHR = null,
    present_modes: ?[]vk.PresentModeKHR = null,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    fn deinit(self: Self) void {
        if (self.formats) |formats| self.allocator.free(formats);
        if (self.present_modes) |present_modes| self.allocator.free(present_modes);
    }
};

fn chooseSwapSurfaceFormat(formats: []vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == vk.Format.b8g8r8a8_srgb and
            format.color_space == vk.ColorSpaceKHR.srgb_nonlinear_khr) return format;
    }

    return formats[0];
}

fn chooseSwapPresentMode(modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    for (modes) |mode| {
        if (mode == vk.PresentModeKHR.mailbox_khr) return mode;
    }

    return vk.PresentModeKHR.fifo_khr;
}

fn chooseSwapExtent(
    vkd: types.DeviceDispatch,
    vk_device: vk.Device,
    capabilities: vk.SurfaceCapabilitiesKHR,
    window_callbacks: *const types.WindowCallbacks,
) !vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) return capabilities.current_extent;

    var size = window_callbacks.getFramebufferSize();

    while (size.width == 0 and size.height == 0) {
        window_callbacks.waitEvents();
        size = window_callbacks.getFramebufferSize();
    }

    try vkd.deviceWaitIdle(vk_device);

    return .{
        .width = std.math.clamp(size.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(size.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

pub fn createSwapChain(
    vki: types.InstanceDispatch,
    vkd: types.DeviceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    vk_device: vk.Device,
    vk_surface: vk.SurfaceKHR,
    window: *const types.WindowCallbacks,
    allocator: std.mem.Allocator,
) !types.SwapchainBasicData {
    const swap_chain_support_details = try querySwapChainSupport(vki, vk_physical_device, vk_surface, allocator);
    defer swap_chain_support_details.deinit();

    const formats = swap_chain_support_details.formats orelse unreachable;
    const present_modes = swap_chain_support_details.present_modes orelse unreachable;
    const capabilities = swap_chain_support_details.capabilities orelse unreachable;

    const format = chooseSwapSurfaceFormat(formats);
    const present_mode = chooseSwapPresentMode(present_modes);
    const extent = try chooseSwapExtent(vkd, vk_device, capabilities, window);

    var image_count = capabilities.min_image_count + 1;

    if (capabilities.max_image_count > 0 and image_count > capabilities.max_image_count) {
        image_count = capabilities.max_image_count;
    }

    const queue_families = try findQueueFamilies(vki, vk_physical_device, vk_surface, allocator);
    const is_one_queue = queue_families.graphicsFamily == queue_families.presentFamily;
    const indices = [_]u32{ queue_families.graphicsFamily, queue_families.presentFamily };

    const swapchain = try vkd.createSwapchainKHR(vk_device, &.{
        .surface = vk_surface,
        .min_image_count = image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = if (is_one_queue) vk.SharingMode.exclusive else vk.SharingMode.concurrent,
        .queue_family_index_count = if (is_one_queue) 0 else 2,
        .p_queue_family_indices = if (is_one_queue) null else &indices,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
    }, null);

    return .{
        .handle = swapchain,
        .format = format.format,
        .extent = extent,
    };
}

fn getSwapchainImages(
    vkd: types.DeviceDispatch,
    vk_device: vk.Device,
    vk_swapchain: vk.SwapchainKHR,
    allocator: std.mem.Allocator,
) ![]vk.Image {
    var image_count: u32 = undefined;

    if (try vkd.getSwapchainImagesKHR(vk_device, vk_swapchain, &image_count, null) != .success) {
        return error.InitializationFailed;
    }

    const images = try allocator.alloc(vk.Image, image_count);
    errdefer allocator.free(images);

    if (try vkd.getSwapchainImagesKHR(vk_device, vk_swapchain, &image_count, images.ptr) != .success) {
        return error.InitializationFailed;
    }

    return images;
}

fn createImageViews(
    vkd: types.DeviceDispatch,
    vk_device: vk.Device,
    swapchain: types.SwapchainBasicData,
    images: []vk.Image,
    allocator: std.mem.Allocator,
) ![]vk.ImageView {
    const views = try allocator.alloc(vk.ImageView, images.len);
    errdefer allocator.free(views);

    for (images, views[0..]) |image, *view| {
        view.* = try vkd.createImageView(vk_device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = swapchain.format,
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

    return views;
}
