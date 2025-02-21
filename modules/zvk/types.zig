const std = @import("std");
const builtin = @import("builtin");

const utils = @import("util");
const vk = @import("vk");

pub const Pipeline = struct {
    handle: vk.Pipeline = .null_handle,
    layout: vk.PipelineLayout = .null_handle,
};

pub const Pipelines = struct {
    pipeline_sprite_opaque: Pipeline = .{},
    pipeline_landscape: Pipeline = .{},
    pipeline_line: Pipeline = .{},
    pipeline_point: Pipeline = .{},
    pipeline_triangles: Pipeline = .{},
    pipeline_text: Pipeline = .{},

    pipeline_present: Pipeline = .{},
    pipeline_gui: Pipeline = .{},

    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    resolved_depth_format: vk.Format = undefined,
    resolved_depth_layout: vk.ImageLayout = undefined,
    resolved_depth_aspect: vk.ImageAspectFlags = undefined,
};

pub const BasicPushConstant = extern struct {
    landscape_size: @Vector(2, u32),
    atlas_size: @Vector(2, u32),
    target_size: @Vector(2, u32),
    camera_pos: @Vector(2, i32),
    alpha_factor: f32,
};

pub const LandscapePushConstant = extern struct {
    landscape_size: @Vector(2, u32),
    target_size: @Vector(2, u32),
    camera_pos: @Vector(2, i32),
};

pub const LandscapeSetupPushConstant = extern struct {
    camera_pos: @Vector(2, i32),
    camera_pos_diff: @Vector(2, i32),
    n_point_lights: u32,
};

pub const TextPushConstant = extern struct {
    atlas_size: @Vector(2, u32),
    target_size: @Vector(2, u32),
    camera_pos: @Vector(2, i32),
    font_sheet_base: @Vector(2, u32),
    base_stride: u32,
    stride_len: u32,
};

pub const SpriteData = extern struct {
    offset: @Vector(2, f32),
    color: @Vector(4, f16),
    pivot: @Vector(2, f16),
    uv_ul: @Vector(2, u16),
    uv_sz: @Vector(2, u16),
    depth: u16, // unsigned normalized [0, 1]
    rot: i16, // signed normalized [-pi; pi]
};

pub const LineData = extern struct {
    points: [2]@Vector(2, f32),
    color: @Vector(4, f16),
    depth: f32,
    alpha_gradient: @Vector(2, f16),
};

pub const PointData = extern struct {
    point: @Vector(3, f32),
    color: @Vector(4, f16),
};

pub const BackgroundData = extern struct {
    offset: @Vector(2, i16),
    ratio: @Vector(2, f16),
    uv_ul: @Vector(2, u16),
    uv_sz: @Vector(2, u16),
    color_top: @Vector(4, u8),
    color_bot: @Vector(4, u8),
    color: @Vector(4, f16),
};

pub const LandscapeData = extern struct {
    offset: @Vector(2, i32),
    size: @Vector(2, i32),
    descriptor: i32,
    depth: f32,
};

pub const VertexData = extern struct {
    point: @Vector(3, f32),
    color: @Vector(4, f16),
    uv: @Vector(2, f32),
};

pub const TextData = extern struct {
    offset: @Vector(3, f32),
    color: @Vector(4, f16),
    char: u32,
};

pub const DrawData = extern union {
    sprite: SpriteData,
    line: LineData,
    point: PointData,
    background: BackgroundData,
    landscape: LandscapeData,
    vertex: VertexData,
    character: TextData,
};

test "DrawDataLayout" {
    try comptime std.testing.expectEqual(32, @sizeOf(DrawData));
    try comptime std.testing.expectEqual(32, @sizeOf(SpriteData));
    try comptime std.testing.expectEqual(32, @sizeOf(LineData));
    try comptime std.testing.expectEqual(32, @sizeOf(PointData));
    try comptime std.testing.expectEqual(32, @sizeOf(BackgroundData));
    try comptime std.testing.expectEqual(24, @sizeOf(LandscapeData));
    try comptime std.testing.expectEqual(32, @sizeOf(VertexData));
    try comptime std.testing.expectEqual(32, @sizeOf(TextData));

    try comptime std.testing.expectEqual(16, @alignOf(DrawData));
    try comptime std.testing.expectEqual(8, @alignOf(SpriteData));
    try comptime std.testing.expectEqual(8, @alignOf(LineData));
    try comptime std.testing.expectEqual(16, @alignOf(PointData));
    try comptime std.testing.expectEqual(8, @alignOf(BackgroundData));
    try comptime std.testing.expectEqual(16, @alignOf(VertexData));
    try comptime std.testing.expectEqual(16, @alignOf(TextData));

    try comptime std.testing.expectEqual(24, @sizeOf(BasicPushConstant));
    try comptime std.testing.expectEqual(40, @sizeOf(TextPushConstant));

    const data: DrawData = undefined; // extern unions are never type checked
    try std.testing.expectEqual(@intFromPtr(&data), @intFromPtr(&data.sprite));
    try std.testing.expectEqual(@intFromPtr(&data), @intFromPtr(&data.line));
    try std.testing.expectEqual(@intFromPtr(&data), @intFromPtr(&data.point));
}

pub const GuiHeader = union(enum) {
    pub const Scissor = struct {
        extent: @Vector(2, u32),
        offset: @Vector(2, i32),
    };

    pub const Indices = struct {
        begin: u32,
        end: u32,
    };

    scissor: Scissor,
    triangles: Indices,
    lines: Indices,
};

pub fn BufferVisible(comptime T: type) type {
    return struct {
        handle: vk.Buffer = .null_handle,
        memory: vk.DeviceMemory = .null_handle,
        requirements: vk.MemoryRequirements = std.mem.zeroes(vk.MemoryRequirements),
        map: []T = &.{},
    };
}

pub const ImageData = struct {
    handle: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    requirements: vk.MemoryRequirements = std.mem.zeroes(vk.MemoryRequirements),
    view: vk.ImageView = .null_handle,
    format: vk.Format = .undefined,
    aspect_mask: vk.ImageAspectFlags = .{},
    extent: vk.Extent2D = std.mem.zeroes(vk.Extent2D),
    map: ?*anyopaque = null,
};

pub fn ImageDataVisible(comptime T: type) type {
    return struct {
        handle: vk.Image = .null_handle,
        memory: vk.DeviceMemory = .null_handle,
        requirements: vk.MemoryRequirements = std.mem.zeroes(vk.MemoryRequirements),
        map: []T = &.{},
    };
}

pub const SwapchainBasicData = struct {
    handle: vk.SwapchainKHR = .null_handle,
    format: vk.Format = .undefined,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
};

pub const NextSwapchainImage = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,

    index: u32,

    image: vk.Image,
    view: vk.ImageView,
    semaphore_image_acquired: vk.Semaphore,
};

pub const SwapchainData = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,

    images: std.BoundedArray(vk.Image, max_images),
    views: std.BoundedArray(vk.ImageView, max_images),

    const max_images = 3;

    pub fn init(basic_data: SwapchainBasicData) @This() {
        return .{
            .handle = basic_data.handle,
            .format = basic_data.format,
            .extent = basic_data.extent,
            .images = std.BoundedArray(vk.Image, max_images).init(0) catch unreachable,
            .views = std.BoundedArray(vk.ImageView, max_images).init(0) catch unreachable,
        };
    }
};

pub const QueueFamilyIndicesIncomplete = struct {
    graphics: ?u32 = null,
    present: ?u32 = null,

    pub fn isComplete(self: @This()) bool {
        _ = self.graphics orelse return false;
        _ = self.present orelse return false;
        return true;
    }

    pub fn complete(self: @This()) QueueFamilyIndicesComplete {
        return utils.meta.unwrapOptionals(self);
    }
};

pub const QueueFamilyIndicesComplete = utils.meta.UnwrapOptionals(QueueFamilyIndicesIncomplete);

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

const apis: []const vk.ApiInfo = &.{
    .{
        .base_commands = .{
            .createInstance = true,
            .enumerateInstanceExtensionProperties = true,
            .enumerateInstanceLayerProperties = true,
            .getInstanceProcAddr = true,
        },
        .instance_commands = getVkInstanceDispatchFlags(),
        .device_commands = .{
            .acquireNextImageKHR = true,
            .allocateCommandBuffers = true,
            .allocateDescriptorSets = true,
            .allocateMemory = true,
            .beginCommandBuffer = true,
            .bindBufferMemory = true,
            .bindImageMemory = true,
            .cmdBeginRendering = true,
            .cmdBindDescriptorSets = true,
            .cmdBindPipeline = true,
            .cmdBindVertexBuffers = true,
            .cmdClearAttachments = true,
            .cmdClearColorImage = true,
            .cmdClearDepthStencilImage = true,
            .cmdCopyBufferToImage = true,
            .cmdCopyImage2 = true,
            .cmdDispatch = true,
            .cmdDraw = true,
            .cmdEndRendering = true,
            .cmdExecuteCommands = true,
            .cmdPipelineBarrier2 = true,
            .cmdPushConstants = true,
            .cmdSetPrimitiveTopology = true,
            .cmdSetScissor = true,
            .cmdSetViewport = true,
            .createBuffer = true,
            .createCommandPool = true,
            .createComputePipelines = true,
            .createDescriptorPool = true,
            .createDescriptorSetLayout = true,
            .createFence = true,
            .createGraphicsPipelines = true,
            .createImage = true,
            .createImageView = true,
            .createPipelineLayout = true,
            .createSampler = true,
            .createSemaphore = true,
            .createShaderModule = true,
            .createSwapchainKHR = true,
            .destroyBuffer = true,
            .destroyCommandPool = true,
            .destroyDescriptorPool = true,
            .destroyDescriptorSetLayout = true,
            .destroyDevice = true,
            .destroyFence = true,
            .destroyImage = true,
            .destroyImageView = true,
            .destroyPipeline = true,
            .destroyPipelineLayout = true,
            .destroySampler = true,
            .destroySemaphore = true,
            .destroyShaderModule = true,
            .destroySwapchainKHR = true,
            .deviceWaitIdle = true,
            .endCommandBuffer = true,
            .freeCommandBuffers = true,
            .freeDescriptorSets = true,
            .freeMemory = true,
            .getBufferMemoryRequirements = true,
            .getDeviceQueue = true,
            .getImageMemoryRequirements = true,
            .getSwapchainImagesKHR = true,
            .mapMemory = true,
            .queuePresentKHR = true,
            .queueSubmit = true,
            .queueWaitIdle = true,
            .resetCommandBuffer = true,
            .resetFences = true,
            .unmapMemory = true,
            .updateDescriptorSets = true,
            .waitForFences = true,
        },
    },
};

fn getVkInstanceDispatchFlags() vk.InstanceCommandFlags {
    var flags = vk.InstanceCommandFlags{
        .createDevice = true,
        .destroyInstance = true,
        .destroySurfaceKHR = true,
        .enumerateDeviceExtensionProperties = true,
        .enumeratePhysicalDevices = true,
        .getDeviceProcAddr = true,
        .getPhysicalDeviceFeatures = true,
        .getPhysicalDeviceFormatProperties = true,
        .getPhysicalDeviceMemoryProperties = true,
        .getPhysicalDeviceProperties = true,
        .getPhysicalDeviceProperties2 = true,
        .getPhysicalDeviceQueueFamilyProperties = true,
        .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
        .getPhysicalDeviceSurfaceFormatsKHR = true,
        .getPhysicalDeviceSurfacePresentModesKHR = true,
        .getPhysicalDeviceSurfaceSupportKHR = true,
    };

    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        flags.createDebugUtilsMessengerEXT = true;
        flags.destroyDebugUtilsMessengerEXT = true;
    }

    return flags;
}

pub const BaseDispatch = vk.BaseWrapper(apis);
pub const InstanceDispatch = vk.InstanceWrapper(apis);
pub const DeviceDispatch = vk.DeviceWrapper(apis);
