const std = @import("std");
const builtin = @import("builtin");

const meta = @import("./meta.zig");
const vk = @import("./vk.zig");

pub const SpriteData = struct {
    pivot: @Vector(2, f32),
    offset: @Vector(2, f32),
    uv_source: @Vector(2, f32),
};

pub fn TypedBuffer(comptime T: type) type {
    return struct {
        handle: vk.Buffer,
        memory: vk.DeviceMemory,
        requirements: vk.MemoryRequirements,
        map: []T,
    };
}

pub const FrameData = struct {
    fence_busy: vk.Fence = .null_handle,
    semaphore_opaque_render_finished: vk.Semaphore = .null_handle,
    semaphore_blend_render_finished: vk.Semaphore = .null_handle,
    semaphore_ui_render_finished: vk.Semaphore = .null_handle,
    semaphore_present_render_finished: vk.Semaphore = .null_handle,

    image_color_main: vk.Image = .null_handle,
    image_depth_main: vk.Image = .null_handle,

    view_color_main: vk.ImageView = .null_handle,
    view_depth_main: vk.ImageView = .null_handle,

    descriptor_set: vk.DescriptorSet = .null_handle,

    draw_buffer: TypedBuffer(u32),

    // ssb_sprite_draw_buffer_opaque
    // ssb_sprite_draw_buffer_blend
    // ssb_ui_draw_buffer
};

pub const SwapchainBasicData = struct {
    handle: vk.SwapchainKHR = .null_handle,
    format: vk.Format = .undefined,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
};

pub const SwapchainData = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,

    images: std.BoundedArray(vk.Image, max_images),
    views: std.BoundedArray(vk.ImageView, max_images),

    semaphores_image_acquired: std.BoundedArray(vk.Semaphore, max_images),

    const max_images = 3;

    pub fn init(basic_data: SwapchainBasicData) @This() {
        return .{
            .handle = basic_data.handle,
            .format = basic_data.format,
            .extent = basic_data.extent,
            .images = std.BoundedArray(vk.Image, max_images).init(0) catch unreachable,
            .views = std.BoundedArray(vk.ImageView, max_images).init(0) catch unreachable,
            .semaphores_image_acquired = std.BoundedArray(vk.Semaphore, max_images).init(0) catch unreachable,
        };
    }
};

pub const QueueFamilyIndicesIncomplete = struct {
    graphicsFamily: ?u32 = null,
    presentFamily: ?u32 = null,

    pub fn isComplete(self: @This()) bool {
        _ = self.graphicsFamily orelse return false;
        _ = self.presentFamily orelse return false;
        return true;
    }

    pub fn complete(self: @This()) QueueFamilyIndicesComplete {
        return meta.unwrapOptionals(self);
    }
};

pub const QueueFamilyIndicesComplete = meta.UnwrapOptionals(QueueFamilyIndicesIncomplete);

pub const WindowCallbacks = struct {
    p_create_window_surface: *const fn (self: *const @This(), instance: vk.Instance) anyerror!vk.SurfaceKHR,
    p_get_framebuffer_size: *const fn (self: *const @This()) vk.Extent2D,
    p_get_required_instance_extensions: *const fn (self: *const @This()) anyerror![][*:0]const u8,
    p_wait_events: *const fn (self: *const @This()) void,

    pub inline fn createWindowSurface(self: *const @This(), instance: vk.Instance) anyerror!vk.SurfaceKHR {
        return self.p_create_window_surface(self, instance);
    }

    pub inline fn getFramebufferSize(self: *const @This()) vk.Extent2D {
        return self.p_get_framebuffer_size(self);
    }

    pub inline fn getRequiredInstanceExtensions(self: *const @This()) anyerror![][*:0]const u8 {
        return self.p_get_required_instance_extensions(self);
    }

    pub inline fn waitEvents(self: *const @This()) void {
        return self.p_wait_events(self);
    }
};

pub const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
});

fn getVkInstanceDispatchFlags() vk.InstanceCommandFlags {
    var flags = vk.InstanceCommandFlags{
        .destroyInstance = true,
        .enumeratePhysicalDevices = true,
        .getPhysicalDeviceProperties = true,
        .getPhysicalDeviceMemoryProperties = true,
        .getPhysicalDeviceFeatures = true,
        .getPhysicalDeviceQueueFamilyProperties = true,
        .getPhysicalDeviceSurfaceSupportKHR = true,
        .getDeviceProcAddr = true,
        .createDevice = true,
        .destroySurfaceKHR = true,
        .enumerateDeviceExtensionProperties = true,
        .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
        .getPhysicalDeviceSurfaceFormatsKHR = true,
        .getPhysicalDeviceSurfacePresentModesKHR = true,
        .getPhysicalDeviceFormatProperties = true,
    };

    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        flags.createDebugUtilsMessengerEXT = true;
        flags.destroyDebugUtilsMessengerEXT = true;
    }

    return flags;
}

pub const InstanceDispatch = vk.InstanceWrapper(getVkInstanceDispatchFlags());

pub const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,
    .createImageView = true,
    .destroyImageView = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .createFence = true,
    .destroyFence = true,
    .createSemaphore = true,
    .destroySemaphore = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .createGraphicsPipelines = true,
    .destroyPipelineLayout = true,
    .destroyPipeline = true,
    .beginCommandBuffer = true,
    .cmdBindPipeline = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdDraw = true,
    .endCommandBuffer = true,
    .waitForFences = true,
    .resetFences = true,
    .resetCommandBuffer = true,
    .acquireNextImageKHR = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .deviceWaitIdle = true,
    .cmdBeginRendering = true,
    .cmdEndRendering = true,
    .cmdPipelineBarrier2 = true,
    .allocateMemory = true,
    .freeMemory = true,
    .mapMemory = true,
    .unmapMemory = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .getBufferMemoryRequirements = true,
    .bindBufferMemory = true,
    .cmdBindVertexBuffers = true,
    .cmdClearAttachments = true,
    .cmdClearColorImage = true,
    .createImage = true,
    .getImageMemoryRequirements = true,
    .destroyImage = true,
    .bindImageMemory = true,
    .cmdCopyBufferToImage = true,
    .queueWaitIdle = true,
    .createSampler = true,
    .destroySampler = true,
    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,
    .createDescriptorPool = true,
    .destroyDescriptorPool = true,
    .allocateDescriptorSets = true,
    .freeDescriptorSets = true,
    .updateDescriptorSets = true,
    .cmdBindDescriptorSets = true,
    .cmdPushConstants = true,
    .cmdClearDepthStencilImage = true,
});
