const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("./vk.zig");
const stb = @cImport(@cInclude("stb/stb_image.h"));
const zva = @import("./zva.zig");
const Vulkan = @import("./VulkanBackend.zig");
const vk_types = @import("./vulkan_types.zig");

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

pub fn run2() !void {
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

    const vk_backend = try Vulkan.init(
        allocator,
        @as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)),
        &window_ctx.child,
    );
    defer vk_backend.deinit();

    vk_backend.loop();
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

    var window_ctx = FramebufferSizeCallbackCtx{};
    window.setUserPointer(&window_ctx);
    window.setFramebufferSizeCallback(glfwFramebufferSizeCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const vkb = try BaseDispatch.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));
    const vk_instance = try createVulkanInstance(vkb, allocator);

    const vki = try InstanceDispatch.load(vk_instance, vkb.dispatch.vkGetInstanceProcAddr);
    defer vki.destroyInstance(vk_instance, null);

    const vk_debug_messenger = try createDebugMessenger(vki, vk_instance);
    defer destroyDebugMessenger(vki, vk_instance, vk_debug_messenger);

    var vk_surface: vk.SurfaceKHR = undefined;

    if (@as(vk.Result, @enumFromInt(glfw.createWindowSurface(vk_instance, window, null, &vk_surface))) != .success) {
        std.log.err("Failed to create vulkan surface (GLFW)", .{});
        return error.InitializationFailed;
    }
    defer vki.destroySurfaceKHR(vk_instance, vk_surface, null);

    const vk_physical_device = try pickPhysicalDevice(vki, vk_instance, vk_surface, allocator);
    const vk_queue_families = try findQueueFamilies(vki, vk_physical_device, vk_surface, allocator);
    const vk_device = try createLogicalDevice(vki, vk_physical_device, vk_queue_families);

    const vkd = try DeviceDispatch.load(vk_device, vki.dispatch.vkGetDeviceProcAddr);
    defer vkd.destroyDevice(vk_device, null);

    var zva_allocator = try zva.Allocator.init(allocator, createZvaFunctionPointers(vki, vkd), vk_physical_device, vk_device, 4);
    defer zva_allocator.deinit();

    var swapchain_metadata = try createSwapChain(vki, vkd, vk_physical_device, vk_device, vk_surface, window, allocator);
    defer vkd.destroySwapchainKHR(vk_device, swapchain_metadata.vk_swapchain, null);

    const swapchain_images = try getSwapchainImages(vkd, vk_device, swapchain_metadata.vk_swapchain, allocator);
    defer allocator.free(swapchain_images);

    const swapchain_image_views = try createImageViews(vkd, vk_device, swapchain_metadata, swapchain_images, allocator);
    defer {
        for (swapchain_image_views) |view| vkd.destroyImageView(vk_device, view, null);
        allocator.free(swapchain_image_views);
    }

    const depth_image = try DepthImage.init(vki, vkd, vk_device, vk_physical_device, swapchain_metadata.extent);
    defer depth_image.deinit();

    const vk_shader_vert = try createShaderModule(vkd, vk_device, "shaders/triangle.vert.spv", allocator);
    defer vkd.destroyShaderModule(vk_device, vk_shader_vert, null);
    const vk_shader_frag = try createShaderModule(vkd, vk_device, "shaders/triangle.frag.spv", allocator);
    defer vkd.destroyShaderModule(vk_device, vk_shader_frag, null);

    const vk_pipeline_shader_stage_create_info = createPipelineShaderStageCreateInfo(vk_shader_vert, vk_shader_frag);

    const vk_dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const vk_dynamic_state = vk.PipelineDynamicStateCreateInfo{ // OK
        .dynamic_state_count = vk_dynamic_states.len,
        .p_dynamic_states = &vk_dynamic_states,
    };

    const vk_assembly_state_create_info = vk.PipelineInputAssemblyStateCreateInfo{ // OK
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const vk_viewport = vk.Viewport{ // OK
        .x = 0,
        .y = 0,
        .width = @floatFromInt(swapchain_metadata.extent.width),
        .height = @floatFromInt(swapchain_metadata.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const vk_scissor = vk.Rect2D{ // OK
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain_metadata.extent,
    };

    const vk_viewport_state = vk.PipelineViewportStateCreateInfo{ // OK
        .viewport_count = 1,
        .p_viewports = &[_]vk.Viewport{vk_viewport},
        .scissor_count = 1,
        .p_scissors = &[_]vk.Rect2D{vk_scissor},
    };

    const vk_rasterizer = vk.PipelineRasterizationStateCreateInfo{ // OK
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const vk_multisampling = vk.PipelineMultisampleStateCreateInfo{ // OK
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const vk_color_blend_attachment = vk.PipelineColorBlendAttachmentState{ // OK
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    const vk_depth_stencil_attachment = vk.PipelineDepthStencilStateCreateInfo{
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

    const vk_color_blending = vk.PipelineColorBlendStateCreateInfo{ // OK
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{vk_color_blend_attachment},
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const vk_descriptor_set_layout = try createDescriptorSetLayout(vkd, vk_device);
    defer vkd.destroyDescriptorSetLayout(vk_device, vk_descriptor_set_layout, null);

    const vk_descriptor_pool = try createDescriptorPool(vkd, vk_device);
    defer vkd.destroyDescriptorPool(vk_device, vk_descriptor_pool, null);

    const vk_descriptor_sets = try createDescriptorSets(vkd, vk_device, vk_descriptor_set_layout, vk_descriptor_pool);
    defer destroyDescriptorSets(vkd, vk_device, vk_descriptor_pool, &vk_descriptor_sets);

    const pipeline_layout = try createGraphicsPipeline(vkd, vk_device, vk_descriptor_set_layout);
    defer vkd.destroyPipelineLayout(vk_device, pipeline_layout, null);

    var graphics_pipeline: [1]vk.Pipeline = undefined;

    const render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = asConstArray(&swapchain_metadata.image_format),
        .depth_attachment_format = depth_image.format,
        .view_mask = 0,
        .stencil_attachment_format = .undefined,
    };

    const pipeline_info = [1]vk.GraphicsPipelineCreateInfo{
        .{
            .stage_count = 2,
            .p_stages = &vk_pipeline_shader_stage_create_info,
            .p_vertex_input_state = &.{},
            .p_input_assembly_state = &vk_assembly_state_create_info,
            .p_viewport_state = &vk_viewport_state,
            .p_rasterization_state = &vk_rasterizer,
            .p_multisample_state = &vk_multisampling,
            .p_depth_stencil_state = &vk_depth_stencil_attachment,
            .p_color_blend_state = &vk_color_blending,
            .p_dynamic_state = &vk_dynamic_state,
            .layout = pipeline_layout,
            .p_next = &render_info,
            .subpass = 0,
            .base_pipeline_index = 0,
        },
    };

    if (try vkd.createGraphicsPipelines(vk_device, .null_handle, 1, &pipeline_info, null, &graphics_pipeline) != .success) {
        @panic("I don't know anymore");
    }
    defer vkd.destroyPipeline(vk_device, graphics_pipeline[0], null);

    const square_vertices = [3]VertexType{
        .{
            .pos = .{ 0.0, -0.5, 0 },
            .col = .{ 1, 0, 0 },
        },
        .{
            .pos = .{ 0.5, 0.5, 0 },
            .col = .{ 0, 0, 0 },
        },
        .{
            .pos = .{ -0.5, 0.5, 0 },
            .col = .{ 0, 0, 0 },
        },
    };

    // VERTEX BUFFER SHIT
    const vk_vertex_buffer = try vkd.createBuffer(vk_device, &.{
        .size = @sizeOf(@TypeOf(square_vertices)),
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer vkd.destroyBuffer(vk_device, vk_vertex_buffer, null);

    const vk_vb_mem_reqs = vkd.getBufferMemoryRequirements(vk_device, vk_vertex_buffer);

    const vk_dev_mem = try vkd.allocateMemory(vk_device, &.{
        .allocation_size = vk_vb_mem_reqs.size,
        .memory_type_index = try findMemoryType(
            vki,
            vk_physical_device,
            vk_vb_mem_reqs.memory_type_bits,
            .{ .host_coherent_bit = true, .host_visible_bit = true },
        ),
    }, null);
    defer vkd.freeMemory(vk_device, vk_dev_mem, null);

    try vkd.bindBufferMemory(vk_device, vk_vertex_buffer, vk_dev_mem, 0);
    {
        const map = try vkd.mapMemory(vk_device, vk_dev_mem, 0, @sizeOf(@TypeOf(square_vertices)), .{}) orelse unreachable;
        @memcpy(@as([*]VertexType, @alignCast(@ptrCast(map))), &square_vertices);
        vkd.unmapMemory(vk_device, vk_dev_mem);
    }
    // END OF VERTEX BUFFER SHIT

    // SSBO SHIT
    const vk_ssb = try vkd.createBuffer(vk_device, &.{
        .size = @sizeOf(@TypeOf(square_vertices)),
        .usage = .{ .storage_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer vkd.destroyBuffer(vk_device, vk_ssb, null);

    const vk_ssb_mem_reqs = vkd.getBufferMemoryRequirements(vk_device, vk_ssb);

    const vk_ssb_mem = try vkd.allocateMemory(vk_device, &.{
        .allocation_size = vk_ssb_mem_reqs.size,
        .memory_type_index = try findMemoryType(
            vki,
            vk_physical_device,
            vk_ssb_mem_reqs.memory_type_bits,
            .{ .host_coherent_bit = true, .host_visible_bit = true },
        ),
    }, null);
    defer vkd.freeMemory(vk_device, vk_ssb_mem, null);

    try vkd.bindBufferMemory(vk_device, vk_ssb, vk_ssb_mem, 0);
    {
        const map: [*]VertexType = @alignCast(@ptrCast(try vkd.mapMemory(vk_device, vk_ssb_mem, 0, @sizeOf(@TypeOf(square_vertices)), .{}) orelse unreachable));
        @memcpy(map, &square_vertices);
        vkd.unmapMemory(vk_device, vk_ssb_mem);
    }
    // SSBO SHIT END

    const vk_graphic_queue = vkd.getDeviceQueue(vk_device, vk_queue_families.graphicsFamily.?, 0);
    const vk_present_queue = vkd.getDeviceQueue(vk_device, vk_queue_families.presentFamily.?, 0);

    const vk_graphic_command_pool = try createCommandPool(vkd, vk_device, vk_queue_families.graphicsFamily.?);
    defer vkd.destroyCommandPool(vk_device, vk_graphic_command_pool, null);
    const vk_present_command_pool = try createCommandPool(vkd, vk_device, vk_queue_families.presentFamily.?);
    defer vkd.destroyCommandPool(vk_device, vk_present_command_pool, null);

    const vk_graphic_command_buffers = try createCommandBuffer(vkd, vk_device, vk_graphic_command_pool);
    defer vkd.freeCommandBuffers(vk_device, vk_graphic_command_pool, vk_graphic_command_buffers.len, &vk_graphic_command_buffers);
    const vk_present_command_buffers = try createCommandBuffer(vkd, vk_device, vk_present_command_pool);
    defer vkd.freeCommandBuffers(vk_device, vk_present_command_pool, vk_present_command_buffers.len, &vk_present_command_buffers);

    const image_data = try createImage(vkd, vki, vk_device, vk_physical_device, vk_graphic_queue, vk_graphic_command_pool);
    defer image_data.deinit();

    const texture_view = try createTextureImageView(vkd, vk_device, image_data.image, .r8g8b8a8_srgb);
    defer vkd.destroyImageView(vk_device, texture_view, null);

    const sampler = try createTextureSampler(vkd, vki, vk_device, vk_physical_device);
    defer vkd.destroySampler(vk_device, sampler, null);

    configureDescriptorSets(
        vkd,
        vk_device,
        vk_descriptor_sets[0..],
        .shader_read_only_optimal,
        texture_view,
        sampler,
        vk.DescriptorBufferInfo{
            .buffer = vk_ssb,
            .offset = 0,
            .range = @sizeOf(@TypeOf(square_vertices)),
        },
    );

    var sync = try BaseSyncObjects.init(vkd, vk_device);
    defer sync.deinit(vkd, vk_device);

    var timer = try std.time.Timer.start();
    var timer_fps = try std.time.Timer.start();
    var frame_count: u32 = 0;

    while (!window.shouldClose()) {
        glfw.pollEvents();

        const t1 = timer.read();
        _ = t1; // autofix

        const draw_frame_result = drawFrame(
            vkd,
            vk_device,
            &sync,
            swapchain_metadata,
            vk_graphic_command_buffers[sync.current_index],
            graphics_pipeline[0],
            vk_graphic_queue,
            vk_present_queue,
            swapchain_images,
            swapchain_image_views,
            vk_ssb_mem,
            @as(f32, @floatFromInt(timer.read())) * 1e-9,
            vk_descriptor_sets[sync.current_index],
            pipeline_layout,
            &depth_image,
        ) catch |err| blk: {
            switch (err) {
                error.OutOfDateKHR => break :blk vk.Result.error_out_of_date_khr,
                else => return err,
            }
        };

        defer sync.advance();

        switch (draw_frame_result) {
            else => @panic("drawFrameError"),
            .success => {},
            .error_out_of_date_khr, .suboptimal_khr => {
                recreateSwapChain(
                    vki,
                    vkd,
                    vk_device,
                    vk_physical_device,
                    vk_surface,
                    window,
                    &swapchain_metadata,
                    swapchain_images,
                    swapchain_image_views,
                    allocator,
                ) catch {
                    @panic("Swapchain recreation cannot fail");
                };
            },
        }

        if (window_ctx.wasUpdated()) {
            recreateSwapChain(
                vki,
                vkd,
                vk_device,
                vk_physical_device,
                vk_surface,
                window,
                &swapchain_metadata,
                swapchain_images,
                swapchain_image_views,
                allocator,
            ) catch {
                @panic("Swapchain recreation cannot fail");
            };

            window_ctx.reset();
        }

        frame_count += 1;

        if (timer_fps.read() > 1_000_000_000) {
            timer_fps.reset();

            // const td = @as(f32, @floatFromInt(timer.read() - t1)) * 1e-3;

            var buffer: [64:0]u8 = undefined;
            var stream = std.io.fixedBufferStream(buffer[0..]);

            try std.fmt.format(stream.writer(), "GFX ms: {d}\x00", .{frame_count});

            window.setTitle(&buffer);
            frame_count = 0;
        }
    }

    try vkd.deviceWaitIdle(vk_device);
}

const expected_debug_layers = if (builtin.mode == .Debug) [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
} else [_][*:0]const u8{};

fn createVulkanInstance(vkb: BaseDispatch, allocator: std.mem.Allocator) !vk.Instance {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const glfw_extensions = glfw.getRequiredInstanceExtensions() orelse {
        const err = glfw.mustGetError();
        std.log.err("Failed to get required vulkan instance extensions: {s}", .{err.description});
        return error.InitializationFailed;
    };

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

fn createDebugMessenger(vki: InstanceDispatch, vk_instance: vk.Instance) !?vk.DebugUtilsMessengerEXT {
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

fn destroyDebugMessenger(vki: InstanceDispatch, vk_instance: vk.Instance, debug_messenger_opt: ?vk.DebugUtilsMessengerEXT) void {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return;

    const debug_messenger = debug_messenger_opt orelse return;
    vki.destroyDebugUtilsMessengerEXT(vk_instance, debug_messenger, null);
}

fn pickPhysicalDevice(vki: InstanceDispatch, vk_instance: vk.Instance, vk_surface: vk.SurfaceKHR, allocator: std.mem.Allocator) !vk.PhysicalDevice {
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

fn isDeviceSuitable(vki: InstanceDispatch, vk_physical_device: vk.PhysicalDevice, vk_surface: vk.SurfaceKHR, allocator: std.mem.Allocator) !bool {
    const indices = try findQueueFamilies(vki, vk_physical_device, vk_surface, allocator);

    if (!indices.isComplete()) return false;
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

fn checkExtensionSupport(vki: InstanceDispatch, vk_physical_device: vk.PhysicalDevice, allocator: std.mem.Allocator) !bool {
    var extension_count: u32 = undefined;
    if (try vki.enumerateDeviceExtensionProperties(vk_physical_device, null, &extension_count, null) != .success) unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const extension_properties = try arena.allocator().alloc(vk.ExtensionProperties, extension_count);
    if (try vki.enumerateDeviceExtensionProperties(vk_physical_device, null, &extension_count, extension_properties.ptr) != .success) unreachable;

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

fn findQueueFamilies(
    vki: InstanceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    vk_surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !QueueFamilyIndices {
    var indices = QueueFamilyIndices{};
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

        if (indices.presentFamily == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(vk_physical_device, @intCast(i), vk_surface)) == vk.TRUE) {
            indices.presentFamily = @intCast(i);
        }

        if (indices.isComplete()) break;
    }

    return indices;
}

fn createLogicalDevice(vki: InstanceDispatch, vk_physical_device: vk.PhysicalDevice, queue_family_indices: QueueFamilyIndices) !vk.Device {
    const priority = [_]f32{1.0};

    const queue_create_infos = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = queue_family_indices.graphicsFamily.?,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = queue_family_indices.presentFamily.?,
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

fn querySwapChainSupport(
    vki: InstanceDispatch,
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

        if (try vki.getPhysicalDeviceSurfaceFormatsKHR(vk_physical_device, vk_surface, &format_count, formats.ptr) != .success) {
            return error.InitializationFailed;
        }

        details.formats = formats;
    }

    var present_mode_count: u32 = undefined;

    if (try vki.getPhysicalDeviceSurfacePresentModesKHR(vk_physical_device, vk_surface, &present_mode_count, null) != .success) {
        return error.InitializationFailed;
    }

    if (present_mode_count > 0) {
        const present_modes = try details.allocator.alloc(vk.PresentModeKHR, present_mode_count);

        if (try vki.getPhysicalDeviceSurfacePresentModesKHR(vk_physical_device, vk_surface, &present_mode_count, present_modes.ptr) != .success) {
            return error.InitializationFailed;
        }

        details.present_modes = present_modes;
    }

    return details;
}

fn chooseSwapSurfaceFormat(formats: []vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == vk.Format.b8g8r8a8_srgb and format.color_space == vk.ColorSpaceKHR.srgb_nonlinear_khr) return format;
    }

    return formats[0];
}

fn chooseSwapPresentMode(modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    for (modes) |mode| {
        if (mode == vk.PresentModeKHR.mailbox_khr) return mode;
    }

    return vk.PresentModeKHR.fifo_khr;
}

fn chooseSwapExtent(vkd: DeviceDispatch, vk_device: vk.Device, capabilities: vk.SurfaceCapabilitiesKHR, window: glfw.Window) !vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) return capabilities.current_extent;

    var size = window.getFramebufferSize();

    while (size.width == 0 and size.height == 0) {
        glfw.waitEvents();
        size = window.getFramebufferSize();
    }

    try vkd.deviceWaitIdle(vk_device);

    return .{
        .width = std.math.clamp(size.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(size.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

const SwapchainMetadata = struct {
    vk_swapchain: vk.SwapchainKHR,
    image_format: vk.Format,
    extent: vk.Extent2D,
};

fn createSwapChain(
    vki: InstanceDispatch,
    vkd: DeviceDispatch,
    vk_physical_device: vk.PhysicalDevice,
    vk_device: vk.Device,
    vk_surface: vk.SurfaceKHR,
    window: glfw.Window,
    allocator: std.mem.Allocator,
) !SwapchainMetadata {
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
    const is_one_queue = queue_families.graphicsFamily.? == queue_families.presentFamily.?;
    const indices = [_]u32{ queue_families.graphicsFamily.?, queue_families.presentFamily.? };

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
        .vk_swapchain = swapchain,
        .image_format = format.format,
        .extent = extent,
    };
}

fn getSwapchainImages(vkd: DeviceDispatch, vk_device: vk.Device, vk_swapchain: vk.SwapchainKHR, allocator: std.mem.Allocator) ![]vk.Image {
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
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    swapchain: SwapchainMetadata,
    images: []vk.Image,
    allocator: std.mem.Allocator,
) ![]vk.ImageView {
    const views = try allocator.alloc(vk.ImageView, images.len);
    errdefer allocator.free(views);

    for (images, views[0..]) |image, *view| {
        view.* = try vkd.createImageView(vk_device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = swapchain.image_format,
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

fn recreateSwapChain(
    vki: InstanceDispatch,
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    vk_physical_device: vk.PhysicalDevice,
    vk_surface: vk.SurfaceKHR,
    window: glfw.Window,
    swapchain_metadata: *SwapchainMetadata,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    allocator: std.mem.Allocator,
) !void {
    try vkd.deviceWaitIdle(vk_device);

    for (swapchain_image_views) |view| vkd.destroyImageView(vk_device, view, null);
    vkd.destroySwapchainKHR(vk_device, swapchain_metadata.vk_swapchain, null);

    swapchain_metadata.* = try createSwapChain(vki, vkd, vk_physical_device, vk_device, vk_surface, window, allocator);

    var image_count: u32 = undefined;

    if (try vkd.getSwapchainImagesKHR(vk_device, swapchain_metadata.vk_swapchain, &image_count, null) != .success) {
        return error.InitializationFailed;
    }

    if (image_count != swapchain_images.len) @panic("Why did we get different number of images?");

    if (try vkd.getSwapchainImagesKHR(vk_device, swapchain_metadata.vk_swapchain, &image_count, swapchain_images.ptr) != .success) {
        return error.InitializationFailed;
    }

    for (swapchain_images, swapchain_image_views[0..]) |image, *view| {
        view.* = try vkd.createImageView(vk_device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = swapchain_metadata.image_format,
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

fn createCommandPool(vkd: DeviceDispatch, vk_device: vk.Device, queue_index: u32) !vk.CommandPool {
    return try vkd.createCommandPool(vk_device, &.{
        .queue_family_index = queue_index,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
}

fn createCommandBuffer(vkd: DeviceDispatch, vk_device: vk.Device, vk_command_pool: vk.CommandPool) ![max_images_in_flight]vk.CommandBuffer {
    var buffers: [max_images_in_flight]vk.CommandBuffer = undefined;

    try vkd.allocateCommandBuffers(vk_device, &.{
        .command_buffer_count = buffers.len,
        .level = .primary,
        .command_pool = vk_command_pool,
    }, &buffers);

    return buffers;
}

fn createFence(vkd: DeviceDispatch, vk_device: vk.Device, flags: vk.FenceCreateFlags) !vk.Fence {
    return try vkd.createFence(vk_device, &.{ .flags = flags }, null);
}

fn createSemaphore(vkd: DeviceDispatch, vk_device: vk.Device, flags: vk.SemaphoreCreateFlags) !vk.Semaphore {
    return try vkd.createSemaphore(vk_device, &.{ .flags = flags }, null);
}

const max_images_in_flight = 2;

const BaseSyncObjects = struct {
    sem_image_available: [max_images_in_flight]vk.Semaphore,
    sem_render_finished: [max_images_in_flight]vk.Semaphore,
    fen_in_flight: [max_images_in_flight]vk.Fence,
    // fen_buffer: vk.Fence,

    current_index: u32,

    const Self = @This();

    pub fn init(vkd: DeviceDispatch, vk_device: vk.Device) !Self {
        var self: Self = undefined;

        for (
            self.sem_image_available[0..],
            self.sem_render_finished[0..],
            self.fen_in_flight[0..],
        ) |*sem_ia, *sem_rf, *fen_if| {
            sem_ia.* = try createSemaphore(vkd, vk_device, .{});
            sem_rf.* = try createSemaphore(vkd, vk_device, .{});
            fen_if.* = try createFence(vkd, vk_device, .{ .signaled_bit = true });
        }

        // self.fen_buffer = try createFence(vkd, vk_device, .{ .signaled_bit = true });
        self.current_index = 0;

        return self;
    }

    pub fn deinit(self: *Self, vkd: DeviceDispatch, vk_device: vk.Device) void {
        for (
            self.sem_image_available[0..],
            self.sem_render_finished[0..],
            self.fen_in_flight[0..],
        ) |sem_ia, sem_rf, fen_if| {
            vkd.destroySemaphore(vk_device, sem_ia, null);
            vkd.destroySemaphore(vk_device, sem_rf, null);
            vkd.destroyFence(vk_device, fen_if, null);
        }

        // vkd.destroyFence(vk_device, self.fen_buffer, null);
    }

    pub fn advance(self: *Self) void {
        self.current_index += 1;
        if (self.current_index == max_images_in_flight) self.current_index = 0;
    }
};

fn commandBufferBeginInfo(flags: vk.CommandBufferUsageFlags) vk.CommandBufferBeginInfo {
    return vk.CommandBufferBeginInfo{ .flags = flags };
}

fn createShaderModule(vkd: DeviceDispatch, vk_device: vk.Device, path: []const u8, allocator: std.mem.Allocator) !vk.ShaderModule {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const bytecode = try file.readToEndAllocOptions(allocator, stat.size, stat.size, @alignOf(u32), null);
    defer allocator.free(bytecode);

    const info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = @alignCast(@ptrCast(bytecode)),
    };

    return try vkd.createShaderModule(vk_device, &info, null);
}

fn createPipelineShaderStageCreateInfo(vert: vk.ShaderModule, frag: vk.ShaderModule) [2]vk.PipelineShaderStageCreateInfo {
    return [2]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };
}

fn createGraphicsPipeline(vkd: DeviceDispatch, vk_device: vk.Device, vk_dsl: vk.DescriptorSetLayout) !vk.PipelineLayout {
    const push_constant = vk.PushConstantRange{
        .size = 12,
        .offset = 0,
        .stage_flags = .{ .vertex_bit = true },
    };

    const vk_pipeline_layout_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = asConstArray(&vk_dsl),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = asConstArray(&push_constant),
    };

    return try vkd.createPipelineLayout(vk_device, &vk_pipeline_layout_info, null);
}

fn drawFrame(
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    sync: *BaseSyncObjects,
    swapchain_metadata: SwapchainMetadata,
    vk_graphic_command_buffer: vk.CommandBuffer,
    graphics_pipeline: vk.Pipeline,
    vk_graphics_queue: vk.Queue,
    vk_present_queue: vk.Queue,
    images: []vk.Image,
    image_views: []vk.ImageView,
    vk_ssb_mem: vk.DeviceMemory,
    time: f32,
    vk_ds: vk.DescriptorSet,
    vk_pl: vk.PipelineLayout,
    depth_image: *const DepthImage,
) !vk.Result {
    if (try vkd.waitForFences(vk_device, 1, asConstArray(&sync.fen_in_flight[sync.current_index]), vk.TRUE, 1_000_000_000) != .success) {
        @panic("Wait for fences failed");
    }

    if (try vkd.waitForFences(vk_device, 1, asConstArray(&sync.fen_in_flight[1 - sync.current_index]), vk.TRUE, 1_000_000_000) != .success) {
        @panic("Wait for fences failed");
    }

    const next_image_result = try vkd.acquireNextImageKHR(
        vk_device,
        swapchain_metadata.vk_swapchain,
        std.math.maxInt(u64),
        sync.sem_image_available[sync.current_index],
        .null_handle,
    );

    switch (next_image_result.result) {
        .success, .suboptimal_khr => {},
        .error_out_of_date_khr => return next_image_result.result,
        else => @panic("Failed to acquire swap chain image!"),
    }

    {
        const square_vertices = [3]VertexType{
            .{
                .pos = .{ 0.0, -0.5 + @sin(time * 10) * 0.5, 0 },
                .col = .{ 1, 0, 0 },
            },
            .{
                .pos = .{ 0.5, 0.5, 0 },
                .col = .{ 0, 0, 0 },
            },
            .{
                .pos = .{ -0.5, 0.5, 0 },
                .col = .{ 0, 0, 0 },
            },
        };

        const map = try vkd.mapMemory(vk_device, vk_ssb_mem, 0, @sizeOf(@TypeOf(square_vertices)), .{}) orelse unreachable;
        @memcpy(@as([*]VertexType, @alignCast(@ptrCast(map))), &square_vertices);
        vkd.unmapMemory(vk_device, vk_ssb_mem);
    }

    try vkd.resetCommandBuffer(vk_graphic_command_buffer, .{});
    try vkd.beginCommandBuffer(vk_graphic_command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    if (depth_image.hasStencil()) {
        transitionImage(vkd, vk_graphic_command_buffer, depth_image.image, .undefined, .depth_stencil_attachment_optimal, .{ .depth_bit = true, .stencil_bit = true });
    } else {
        transitionImage(vkd, vk_graphic_command_buffer, depth_image.image, .undefined, .depth_attachment_optimal, .{ .depth_bit = true });
    }

    transitionImage(vkd, vk_graphic_command_buffer, images[next_image_result.image_index], .undefined, .general, .{ .color_bit = true });

    const subrange = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_array_layer = 0,
        .layer_count = vk.REMAINING_ARRAY_LAYERS,
        .base_mip_level = 0,
        .level_count = vk.REMAINING_MIP_LEVELS,
    };

    vkd.cmdClearColorImage(vk_graphic_command_buffer, images[next_image_result.image_index], .general, &.{ .float_32 = .{ 0, 0, 0, 0 } }, 1, asConstArray(&subrange));
    transitionImage(vkd, vk_graphic_command_buffer, images[next_image_result.image_index], .general, .color_attachment_optimal, .{ .color_bit = true });

    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = image_views[next_image_result.image_index],
        .image_layout = .color_attachment_optimal,
        .load_op = .load,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    };

    const depth_attachment = vk.RenderingAttachmentInfo{
        .image_view = depth_image.view,
        .image_layout = .depth_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };

    const render_info = vk.RenderingInfo{
        .color_attachment_count = 1,
        .p_color_attachments = asConstArray(&color_attachment),
        .p_depth_attachment = &depth_attachment,
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain_metadata.extent },
        .layer_count = 1,
        .view_mask = 0,
    };

    vkd.cmdBeginRendering(vk_graphic_command_buffer, &render_info);
    vkd.cmdBindPipeline(vk_graphic_command_buffer, .graphics, graphics_pipeline);
    vkd.cmdBindDescriptorSets(vk_graphic_command_buffer, .graphics, vk_pl, 0, 1, asConstArray(&vk_ds), 0, null);

    vkd.cmdSetViewport(vk_graphic_command_buffer, 0, 1, asConstArray(&vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(swapchain_metadata.extent.width),
        .height = @floatFromInt(swapchain_metadata.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }));

    vkd.cmdSetScissor(vk_graphic_command_buffer, 0, 1, asConstArray(&vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain_metadata.extent,
    }));

    {
        vkd.cmdPushConstants(vk_graphic_command_buffer, vk_pl, .{ .vertex_bit = true }, 0, 12, &@Vector(3, f32){ 0.3, 0.1, 0.1 });
        vkd.cmdDraw(vk_graphic_command_buffer, 3, 1, 0, 0);
    }
    {
        vkd.cmdPushConstants(vk_graphic_command_buffer, vk_pl, .{ .vertex_bit = true }, 0, 12, &@Vector(3, f32){ -0.3, 0.2, 0.2 });
        vkd.cmdDraw(vk_graphic_command_buffer, 3, 1, 0, 0);
    }

    vkd.cmdEndRendering(vk_graphic_command_buffer);
    transitionImage(vkd, vk_graphic_command_buffer, images[next_image_result.image_index], .color_attachment_optimal, .present_src_khr, .{ .color_bit = true });
    try vkd.endCommandBuffer(vk_graphic_command_buffer);

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = asConstArray(&sync.sem_image_available[sync.current_index]),
        .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }},
        .command_buffer_count = 1,
        .p_command_buffers = asConstArray(&vk_graphic_command_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = asConstArray(&sync.sem_render_finished[sync.current_index]),
    };

    try vkd.resetFences(vk_device, 1, asConstArray(&sync.fen_in_flight[sync.current_index]));
    try vkd.queueSubmit(vk_graphics_queue, 1, asConstArray(&submit_info), sync.fen_in_flight[sync.current_index]);

    return try vkd.queuePresentKHR(vk_present_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = asConstArray(&sync.sem_render_finished[sync.current_index]),
        .swapchain_count = 1,
        .p_swapchains = asConstArray(&swapchain_metadata.vk_swapchain),
        .p_image_indices = asConstArray(&next_image_result.image_index),
        .p_results = null,
    });
}

fn transitionImage(
    vkd: DeviceDispatch,
    cmd: vk.CommandBuffer,
    image: vk.Image,
    src_layout: vk.ImageLayout,
    dst_layout: vk.ImageLayout,
    aspect_flags: vk.ImageAspectFlags,
) void {
    const image_barier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = src_layout,
        .new_layout = dst_layout,
        .image = image,
        .subresource_range = .{
            .aspect_mask = aspect_flags,
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = 0,
        .dst_queue_family_index = 0,
    };

    vkd.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = asConstArray(&image_barier),
    });
}

fn createZvaFunctionPointers(vki: InstanceDispatch, vkd: DeviceDispatch) zva.FunctionPointers {
    return zva.FunctionPointers{
        .getPhysicalDeviceMemoryProperties = vki.dispatch.vkGetPhysicalDeviceMemoryProperties,
        .getPhysicalDeviceProperties = vki.dispatch.vkGetPhysicalDeviceProperties,
        .allocateMemory = vkd.dispatch.vkAllocateMemory,
        .freeMemory = vkd.dispatch.vkFreeMemory,
        .mapMemory = vkd.dispatch.vkMapMemory,
        .unmapMemory = vkd.dispatch.vkUnmapMemory,
    };
}

fn findMemoryType(vki: InstanceDispatch, vk_physical_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const props = vki.getPhysicalDeviceMemoryProperties(vk_physical_device);

    for (0..props.memory_type_count) |i| {
        const properties_match = vk.MemoryPropertyFlags.contains(props.memory_types[i].property_flags, properties);
        const type_match = type_filter & @as(u32, 1) << @intCast(i) != 0;

        if (type_match and properties_match) return @intCast(i);
    }

    return error.MemoryTypeNotFound;
}

const ImageData = struct {
    vkd: DeviceDispatch,
    device: vk.Device,
    image: vk.Image,
    dev_mem: vk.DeviceMemory,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        self.vkd.destroyImage(self.device, self.image, null);
        self.vkd.freeMemory(self.device, self.dev_mem, null);
    }
};

fn createImage(
    vkd: DeviceDispatch,
    vki: InstanceDispatch,
    vk_device: vk.Device,
    vk_physical_device: vk.PhysicalDevice,
    vk_graphics_queue: vk.Queue,
    vk_command_pool: vk.CommandPool,
) !ImageData {
    var stb_x: c_int = 0;
    var stb_y: c_int = 0;
    var stb_channels: c_int = 0;

    const stb_pixels: [*]u8 = @ptrCast(stb.stbi_load("images/crate_16.png", &stb_x, &stb_y, &stb_channels, stb.STBI_rgb_alpha) orelse unreachable);
    defer stb.stbi_image_free(stb_pixels);

    const vk_device_size: vk.DeviceSize = @intCast(stb_x * stb_y * stb.STBI_rgb_alpha);

    const vk_staging_buffer = try vkd.createBuffer(vk_device, &.{
        .size = vk_device_size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer vkd.destroyBuffer(vk_device, vk_staging_buffer, null);

    const vk_dev_mem_reqs_img = vkd.getBufferMemoryRequirements(vk_device, vk_staging_buffer);

    const vk_dev_mem_stag = try vkd.allocateMemory(vk_device, &.{
        .allocation_size = vk_dev_mem_reqs_img.size,
        .memory_type_index = try findMemoryType(
            vki,
            vk_physical_device,
            vk_dev_mem_reqs_img.memory_type_bits,
            .{ .host_coherent_bit = true, .host_visible_bit = true },
        ),
    }, null);
    defer vkd.freeMemory(vk_device, vk_dev_mem_stag, null);

    {
        const map: [*]u8 = @ptrCast(try vkd.mapMemory(vk_device, vk_dev_mem_stag, 0, vk_dev_mem_reqs_img.size, .{}) orelse unreachable);
        defer vkd.unmapMemory(vk_device, vk_dev_mem_stag);

        @memcpy(map, stb_pixels[0..vk_device_size]);
    }

    try vkd.bindBufferMemory(vk_device, vk_staging_buffer, vk_dev_mem_stag, 0);

    const image = try vkd.createImage(vk_device, &.{
        .image_type = .@"2d",
        .extent = .{
            .width = @intCast(stb_x),
            .height = @intCast(stb_y),
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .format = .r8g8b8a8_srgb,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .flags = .{},
    }, null);
    errdefer vkd.destroyImage(vk_device, image, null);

    const img_mem_reqs = vkd.getImageMemoryRequirements(vk_device, image);

    const img_mem = try vkd.allocateMemory(vk_device, &.{
        .allocation_size = img_mem_reqs.size,
        .memory_type_index = try findMemoryType(
            vki,
            vk_physical_device,
            img_mem_reqs.memory_type_bits,
            .{ .device_local_bit = true },
        ),
    }, null);
    errdefer vkd.freeMemory(vk_device, img_mem, null);

    try vkd.bindImageMemory(vk_device, image, img_mem, 0);

    var cmd: vk.CommandBuffer = undefined;

    try vkd.allocateCommandBuffers(vk_device, &.{
        .command_pool = vk_command_pool,
        .command_buffer_count = 1,
        .level = .primary,
    }, asArray(&cmd));
    defer vkd.freeCommandBuffers(vk_device, vk_command_pool, 1, asArray(&cmd));

    try vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = @intCast(stb_x), .height = @intCast(stb_y), .depth = 1 },
    };

    transitionImage(vkd, cmd, image, .undefined, .transfer_dst_optimal, .{ .color_bit = true });
    vkd.cmdCopyBufferToImage(cmd, vk_staging_buffer, image, .transfer_dst_optimal, 1, asConstArray(&region));
    transitionImage(vkd, cmd, image, .transfer_dst_optimal, .shader_read_only_optimal, .{ .color_bit = true });

    try vkd.endCommandBuffer(cmd);

    try vkd.queueSubmit(vk_graphics_queue, 1, &[1]vk.SubmitInfo{.{
        .command_buffer_count = 1,
        .p_command_buffers = asConstArray(&cmd),
    }}, .null_handle);

    try vkd.queueWaitIdle(vk_graphics_queue);

    return .{
        .vkd = vkd,
        .image = image,
        .device = vk_device,
        .dev_mem = img_mem,
    };
}

fn createTextureImageView(vkd: DeviceDispatch, vk_device: vk.Device, vk_image: vk.Image, vk_format: vk.Format) !vk.ImageView {
    return try vkd.createImageView(vk_device, &.{
        .image = vk_image,
        .view_type = .@"2d",
        .format = vk_format,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
    }, null);
}

fn createTextureSampler(vkd: DeviceDispatch, vki: InstanceDispatch, vk_device: vk.Device, vk_physical_device: vk.PhysicalDevice) !vk.Sampler {
    const props = vki.getPhysicalDeviceProperties(vk_physical_device);

    return try vkd.createSampler(vk_device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .anisotropy_enable = vk.TRUE,
        .max_anisotropy = props.limits.max_sampler_anisotropy,
        .border_color = vk.BorderColor.int_transparent_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .nearest,
        .mip_lod_bias = 0,
        .min_lod = 0,
        .max_lod = 0,
    }, null);
}

fn createDescriptorSetLayout(vkd: DeviceDispatch, vk_device: vk.Device) !vk.DescriptorSetLayout {
    const binding_img = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };

    const binding_ssb = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
    };

    const bindings = [_]vk.DescriptorSetLayoutBinding{ binding_img, binding_ssb };

    return try vkd.createDescriptorSetLayout(vk_device, &.{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);
}

fn createDescriptorPool(vkd: DeviceDispatch, vk_device: vk.Device) !vk.DescriptorPool {
    const pool_sizes = vk.DescriptorPoolSize{
        .descriptor_count = 2,
        .type = .combined_image_sampler,
    };

    return try vkd.createDescriptorPool(vk_device, &.{
        .pool_size_count = 1,
        .p_pool_sizes = asConstArray(&pool_sizes),
        .max_sets = 2,
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
}

fn createDescriptorSets(vkd: DeviceDispatch, vk_device: vk.Device, vk_dsl: vk.DescriptorSetLayout, vk_dp: vk.DescriptorPool) ![2]vk.DescriptorSet {
    const dsls = [2]vk.DescriptorSetLayout{ vk_dsl, vk_dsl };

    var dss: [2]vk.DescriptorSet = undefined;

    try vkd.allocateDescriptorSets(vk_device, &.{
        .descriptor_pool = vk_dp,
        .descriptor_set_count = 2,
        .p_set_layouts = &dsls,
    }, &dss);

    return dss;
}

fn destroyDescriptorSets(vkd: DeviceDispatch, vk_device: vk.Device, vk_dp: vk.DescriptorPool, dss: []const vk.DescriptorSet) void {
    vkd.freeDescriptorSets(vk_device, vk_dp, @intCast(dss.len), dss.ptr) catch unreachable;
}

fn configureDescriptorSets(vkd: DeviceDispatch, vk_device: vk.Device, dss: []const vk.DescriptorSet, img_layout: vk.ImageLayout, img_view: vk.ImageView, sampler: vk.Sampler, ssb_info: vk.DescriptorBufferInfo) void {
    for (dss) |ds| {
        const image_info = vk.DescriptorImageInfo{
            .image_layout = img_layout,
            .image_view = img_view,
            .sampler = sampler,
        };

        const write_img = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 0,
            .dst_set = ds,
            .p_image_info = asConstArray(&image_info),
        };

        const write_ssb = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = ds,
            .p_buffer_info = asConstArray(&ssb_info),
        };

        const writes = [_]vk.WriteDescriptorSet{ write_img, write_ssb };

        vkd.updateDescriptorSets(vk_device, writes.len, &writes, 0, null);
    }
}

const DepthImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    mem: vk.DeviceMemory,
    format: vk.Format,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    vk_physical_device: vk.PhysicalDevice,

    const Self = @This();

    const possible_formats = [_]vk.Format{
        .d16_unorm,
        .d32_sfloat,
        .d16_unorm_s8_uint,
        .d24_unorm_s8_uint,
        .d32_sfloat_s8_uint,
    };

    pub fn init(vki: InstanceDispatch, vkd: DeviceDispatch, vk_device: vk.Device, vk_physical_device: vk.PhysicalDevice, size: vk.Extent2D) !Self {
        const format = try findDepthFormat(vki, vk_physical_device);
        const has_stencil = formatHasStencil(format);

        const image = try vkd.createImage(vk_device, &vk.ImageCreateInfo{
            .image_type = .@"2d",
            .extent = .{
                .width = size.width,
                .height = size.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .format = format,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .depth_stencil_attachment_bit = true, .transfer_dst_bit = true },
            .sharing_mode = .exclusive,
            .samples = .{ .@"1_bit" = true },
            .flags = .{},
        }, null);
        errdefer vkd.destroyImage(vk_device, image, null);

        const img_mem_reqs = vkd.getImageMemoryRequirements(vk_device, image);

        const img_mem = try vkd.allocateMemory(vk_device, &.{
            .allocation_size = img_mem_reqs.size,
            .memory_type_index = try findMemoryType(
                vki,
                vk_physical_device,
                img_mem_reqs.memory_type_bits,
                .{ .device_local_bit = true },
            ),
        }, null);
        errdefer vkd.freeMemory(vk_device, img_mem, null);

        try vkd.bindImageMemory(vk_device, image, img_mem, 0);

        const image_view = try vkd.createImageView(vk_device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{
                    .depth_bit = true,
                    .stencil_bit = has_stencil,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer vkd.destroyImageView(vk_device, image_view, null);

        return Self{
            .image = image,
            .view = image_view,
            .mem = img_mem,
            .format = format,
            .vki = vki,
            .vkd = vkd,
            .vk_device = vk_device,
            .vk_physical_device = vk_physical_device,
        };
    }

    fn deinit(self: *const Self) void {
        self.vkd.destroyImageView(self.vk_device, self.view, null);
        self.vkd.freeMemory(self.vk_device, self.mem, null);
        self.vkd.destroyImage(self.vk_device, self.image, null);
    }

    fn findDepthFormat(vki: InstanceDispatch, vk_physical_device: vk.PhysicalDevice) !vk.Format {
        for (possible_formats) |format| {
            const props = vki.getPhysicalDeviceFormatProperties(vk_physical_device, format);
            if (props.optimal_tiling_features.depth_stencil_attachment_bit) {
                return format;
            }
        }

        return error.InitializationFailed;
    }

    fn hasStencil(self: *const DepthImage) bool {
        return formatHasStencil(self.format);
    }

    fn formatHasStencil(format: vk.Format) bool {
        return format == .d16_unorm_s8_uint or
            format == .d24_unorm_s8_uint or
            format == .d32_sfloat_s8_uint;
    }
};
