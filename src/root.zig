const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("./vk.zig");
const stb = @cImport(@cInclude("stb/stb_image.h"));
const Vulkan = @import("./VulkanBackend.zig");
const vk_types = @import("./vulkan_types.zig");

const LandSim = @import("./LandscapeSim.zig");

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
});

fn GetInstanceFlags() vk.InstanceCommandFlags {
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

const InstanceDispatch = vk.InstanceWrapper(GetInstanceFlags());

const DeviceDispatch = vk.DeviceWrapper(.{
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

const VertexType = struct {
    pos: @Vector(3, f32) align(16),
    col: @Vector(3, f32) align(16),

    fn getBindingDescription() [1]vk.VertexInputBindingDescription {
        return .{.{
            .binding = 0,
            .input_rate = .vertex,
            .stride = @sizeOf(VertexType),
        }};
    }

    fn getAttributeDescription() [2]vk.VertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(@This(), "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(@This(), "col"),
            },
        };
    }
};

const Consts = struct {
    const width = 640;
    const height = 480;
};

const QueueFamilyIndices = struct {
    graphicsFamily: ?u32 = null,
    presentFamily: ?u32 = null,

    fn isComplete(self: @This()) bool {
        _ = self.graphicsFamily orelse return false;
        _ = self.presentFamily orelse return false;
        return true;
    }
};

const FramebufferSizeCallbackCtx = struct {
    framebuffer_resized: bool = false,

    const Self = @This();

    fn reset(self: *Self) void {
        self.framebuffer_resized = false;
    }

    fn wasUpdated(self: *Self) bool {
        return self.framebuffer_resized;
    }
};

fn glfwFramebufferSizeCallback(window: glfw.Window, _: u32, _: u32) void {
    var ctx_ptr = window.getUserPointer(FramebufferSizeCallbackCtx) orelse @panic("Must return a valid pointer");
    ctx_ptr.framebuffer_resized = true;
}

fn AsArrayType(comptime T: type) type {
    return std.meta.Child(T);
}

fn asConstArray(ptr: anytype) *const [1]AsArrayType(@TypeOf(ptr)) {
    return ptr;
}

fn asArray(ptr: anytype) *[1]AsArrayType(@TypeOf(ptr)) {
    return ptr;
}

/// Default GLFW error handling callback
fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

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

pub fn run() !void {
    std.log.info("Hello zigra!", .{});

    glfw.setErrorCallback(glfwErrorCallback);

    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = glfw.Window.create(Consts.width, Consts.height, "Vulkan window", null, null, .{
        .resizable = false,
        .client_api = .no_api,
    }) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.InitializationFailed;
    };
    defer window.destroy();

    window.setSizeLimits(
        .{ .width = Consts.width, .height = Consts.height },
        .{ .width = null, .height = null },
    );

    window.setAttrib(.resizable, true);

    var framebuffer_size_callback_ctx = FramebufferSizeCallbackCtx{};
    window.setUserPointer(&framebuffer_size_callback_ctx);
    window.setFramebufferSizeCallback(glfwFramebufferSizeCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const WindowCtx = struct {
        window: glfw.Window,
        child: vk_types.WindowCallbacks = .{
            .p_create_window_surface = &createWindowSurface,
            .p_get_framebuffer_size = &getFramebufferSize,
            .p_get_required_instance_extensions = &getRequiredInstanceExtensions,
            .p_wait_events = &waitEvents,
        },

        fn createWindowSurface(child_ptr: *const vk_types.WindowCallbacks, instance: vk.Instance) anyerror!vk.SurfaceKHR {
            const self = @fieldParentPtr(@This(), "child", child_ptr);
            var surface: vk.SurfaceKHR = undefined;

            const result = @as(vk.Result, @enumFromInt(
                glfw.createWindowSurface(instance, self.window, null, &surface),
            ));

            if (result != .success) return error.GlfwCreateWindowSurface;

            return surface;
        }

        fn getFramebufferSize(child_ptr: *const vk_types.WindowCallbacks) vk.Extent2D {
            const self = @fieldParentPtr(@This(), "child", child_ptr);
            const size = self.window.getFramebufferSize();
            return .{ .width = size.width, .height = size.height };
        }

        fn getRequiredInstanceExtensions(_: *const vk_types.WindowCallbacks) anyerror![][*:0]const u8 {
            return glfw.getRequiredInstanceExtensions() orelse blk: {
                const err = glfw.mustGetError();
                std.log.err("Failed to get required vulkan instance extensions: {s}", .{err.description});
                break :blk error.InitializationFailed;
            };
        }

        fn waitEvents(_: *const vk_types.WindowCallbacks) void {
            glfw.waitEvents();
        }
    };

    const window_ctx = WindowCtx{ .window = window };

    var vk_backend = try Vulkan.init(
        allocator,
        @as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)),
        &window_ctx.child,
    );
    defer vk_backend.deinit();

    var ls = try LandSim.init(allocator);
    defer ls.deinit();

    try ls.loadFromPngFile(.{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } }, "land/TEST_LEVEL.png");

    while (!window.shouldClose()) {
        glfw.pollEvents();

        try vk_backend.frames[vk_backend.frame_index].landscape.recalculateActiveSets(@intCast(vk_backend.camera_pos));
        const set = vk_backend.frames[vk_backend.frame_index].landscape.active_sets.constSlice();
        vk_backend.frames[vk_backend.frame_index].landscape_upload.resize(0) catch unreachable;

        const extent = @Vector(2, i32){ Vulkan.frame_target_width, Vulkan.frame_target_heigth };

        const lsExtent = LandSim.NodeExtent{
            .coord = vk_backend.camera_pos - extent / @Vector(2, i32){ 2, 2 },
            .size = .{ Vulkan.frame_target_width, Vulkan.frame_target_heigth },
        };

        const tc = ls.tileCountForArea(lsExtent);
        std.debug.assert(tc <= 12);

        var tiles: [12]*LandSim.Tile = undefined;
        try ls.ensureArea(lsExtent);
        const used = try ls.fillTilesFromArea(lsExtent, &tiles);

        for (used) |src| for (set) |dst| {
            if (@reduce(.Or, src.coord != dst.tile.coord)) continue;
            std.debug.print("Copied {}, {}\n", .{ src.coord, dst.tile.coord });
            try vk_backend.frames[vk_backend.frame_index].landscape_upload.append(.{ .tile = dst.tile, .data = std.mem.asBytes(&src.matrix) });
        };

        std.debug.print("nodes: {} tiles: {}\n", .{ ls.node_pool.arena.queryCapacity(), ls.tile_pool.arena.queryCapacity() });

        try vk_backend.process();
    }

    std.log.info("vk_backend size: {}", .{@sizeOf(@TypeOf(vk_backend))});
}
