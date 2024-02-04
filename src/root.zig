const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vk");

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
    .createRenderPass = true,
    .createPipelineLayout = true,
    .createGraphicsPipelines = true,
    .destroyRenderPass = true,
    .destroyPipelineLayout = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .beginCommandBuffer = true,
    .cmdBeginRenderPass = true,
    .cmdBindPipeline = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdDraw = true,
    .cmdEndRenderPass = true,
    .endCommandBuffer = true,
    .waitForFences = true,
    .resetFences = true,
    .resetCommandBuffer = true,
    .acquireNextImageKHR = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .deviceWaitIdle = true,
});

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

    var swapchain_metadata = try createSwapChain(vki, vkd, vk_physical_device, vk_device, vk_surface, window, allocator);
    defer vkd.destroySwapchainKHR(vk_device, swapchain_metadata.vk_swapchain, null);

    const swapchain_images = try getSwapchainImages(vkd, vk_device, swapchain_metadata.vk_swapchain, allocator);
    defer allocator.free(swapchain_images);

    const swapchain_image_views = try createImageViews(vkd, vk_device, swapchain_metadata, swapchain_images, allocator);
    defer {
        for (swapchain_image_views) |view| vkd.destroyImageView(vk_device, view, null);
        allocator.free(swapchain_image_views);
    }

    const vk_shader_vert = try createShaderModule(vkd, vk_device, "shaders/triangle.vert.spv", allocator);
    defer vkd.destroyShaderModule(vk_device, vk_shader_vert, null);
    const vk_shader_frag = try createShaderModule(vkd, vk_device, "shaders/triangle.frag.spv", allocator);
    defer vkd.destroyShaderModule(vk_device, vk_shader_frag, null);

    const vk_pipeline_shader_stage_create_info = createPipelineShaderStageCreateInfo(vk_shader_vert, vk_shader_frag);

    const vk_dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const vk_dynamic_state = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = vk_dynamic_states.len,
        .p_dynamic_states = &vk_dynamic_states,
    };

    const vk_vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };

    const vk_assembly_state_create_info = vk.PipelineInputAssemblyStateCreateInfo{
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

    const vk_rasterizer = vk.PipelineRasterizationStateCreateInfo{
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

    const vk_multisampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const vk_color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    const vk_color_blending = vk.PipelineColorBlendStateCreateInfo{ // OK
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{vk_color_blend_attachment},
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const vk_render_pass = try createRenderPass(vkd, vk_device, swapchain_metadata);
    defer vkd.destroyRenderPass(vk_device, vk_render_pass, null);

    const pipeline_layout = try createGraphicsPipeline(vkd, vk_device);
    defer vkd.destroyPipelineLayout(vk_device, pipeline_layout, null);

    var graphics_pipeline: [1]vk.Pipeline = undefined;

    const render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 0,
    };
    _ = render_info; // autofix

    const pipeline_info = [1]vk.GraphicsPipelineCreateInfo{
        .{
            .stage_count = 2,
            .p_stages = &vk_pipeline_shader_stage_create_info,
            .p_vertex_input_state = &vk_vertex_input_info,
            .p_input_assembly_state = &vk_assembly_state_create_info,
            .p_viewport_state = &vk_viewport_state,
            .p_rasterization_state = &vk_rasterizer,
            .p_multisample_state = &vk_multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &vk_color_blending,
            .p_dynamic_state = &vk_dynamic_state,
            .layout = pipeline_layout,
            .render_pass = vk_render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        },
    };

    if (try vkd.createGraphicsPipelines(vk_device, .null_handle, 1, &pipeline_info, null, &graphics_pipeline) != .success) {
        @panic("I don't know anymore");
    }
    defer vkd.destroyPipeline(vk_device, graphics_pipeline[0], null);

    const vk_framebuffers = try createFramebuffers(vkd, vk_device, vk_render_pass, swapchain_metadata, swapchain_image_views, allocator);
    defer destroyFramebuffers(vkd, vk_device, allocator, vk_framebuffers);

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

    var sync = try BaseSyncObjects.init(vkd, vk_device);
    defer sync.deinit(vkd, vk_device);

    while (!window.shouldClose()) {
        glfw.pollEvents();

        const draw_frame_result = drawFrame(
            vkd,
            vk_device,
            &sync,
            swapchain_metadata,
            vk_graphic_command_buffers[sync.current_index],
            vk_render_pass,
            vk_framebuffers,
            graphics_pipeline[0],
            vk_graphic_queue,
            vk_present_queue,
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
                    vk_render_pass,
                    &swapchain_metadata,
                    swapchain_images,
                    swapchain_image_views,
                    vk_framebuffers,
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
                vk_render_pass,
                &swapchain_metadata,
                swapchain_images,
                swapchain_image_views,
                vk_framebuffers,
                allocator,
            ) catch {
                @panic("Swapchain recreation cannot fail");
            };

            window_ctx.reset();
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

    return try vki.createDevice(vk_physical_device, &.{
        .p_queue_create_infos = &queue_create_infos,
        .queue_create_info_count = 1,
        .p_enabled_features = &.{},
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = &required_device_extensions,
        .enabled_layer_count = expected_debug_layers.len,
        .pp_enabled_layer_names = &expected_debug_layers,
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
        .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },
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
    vk_render_pass: vk.RenderPass,
    swapchain_metadata: *SwapchainMetadata,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,
    allocator: std.mem.Allocator,
) !void {
    try vkd.deviceWaitIdle(vk_device);

    for (framebuffers) |framebuffer| vkd.destroyFramebuffer(vk_device, framebuffer, null);
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

    for (framebuffers[0..], swapchain_image_views[0..]) |*framebuffer, image_view| {
        const image_view_slice = [_]vk.ImageView{image_view};

        const create_info = vk.FramebufferCreateInfo{
            .render_pass = vk_render_pass,
            .attachment_count = 1,
            .p_attachments = &image_view_slice,
            .width = swapchain_metadata.extent.width,
            .height = swapchain_metadata.extent.height,
            .layers = 1,
        };

        framebuffer.* = try vkd.createFramebuffer(vk_device, &create_info, null);
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

fn createGraphicsPipeline(vkd: DeviceDispatch, vk_device: vk.Device) !vk.PipelineLayout {
    const vk_pipeline_layout_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 0,
        .p_set_layouts = null,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    };

    return try vkd.createPipelineLayout(vk_device, &vk_pipeline_layout_info, null);
}

fn createRenderPass(vkd: DeviceDispatch, vk_device: vk.Device, swapchain_metadata: SwapchainMetadata) !vk.RenderPass {
    const description = vk.AttachmentDescription{
        .format = swapchain_metadata.image_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = &[_]vk.AttachmentReference{
            .{
                .attachment = 0,
                .layout = .color_attachment_optimal,
            },
        },
    };

    const dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };

    const render_pass_info = vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = &[_]vk.AttachmentDescription{description},
        .subpass_count = 1,
        .p_subpasses = &[_]vk.SubpassDescription{subpass},
        .dependency_count = 1,
        .p_dependencies = asConstArray(&dependency),
    };

    return try vkd.createRenderPass(vk_device, &render_pass_info, null);
}

fn createFramebuffers(
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    vk_render_pass: vk.RenderPass,
    swapchain_metadata: SwapchainMetadata,
    image_views: []vk.ImageView,
    allocator: std.mem.Allocator,
) ![]vk.Framebuffer {
    var framebuffers = try allocator.alloc(vk.Framebuffer, image_views.len);
    errdefer allocator.free(framebuffers);

    for (framebuffers[0..], image_views[0..]) |*framebuffer, image_view| {
        const image_view_slice = [_]vk.ImageView{image_view};

        const create_info = vk.FramebufferCreateInfo{
            .render_pass = vk_render_pass,
            .attachment_count = 1,
            .p_attachments = &image_view_slice,
            .width = swapchain_metadata.extent.width,
            .height = swapchain_metadata.extent.height,
            .layers = 1,
        };

        framebuffer.* = try vkd.createFramebuffer(vk_device, &create_info, null);
    }

    return framebuffers;
}

fn destroyFramebuffers(
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    allocator: std.mem.Allocator,
    framebuffers: []vk.Framebuffer,
) void {
    for (framebuffers) |framebuffer| {
        vkd.destroyFramebuffer(vk_device, framebuffer, null);
    }

    allocator.free(framebuffers);
}

fn recordCommandBuffer(
    vkd: DeviceDispatch,
    vk_command_buffer: vk.CommandBuffer,
    index: u32,
    vk_render_pass: vk.RenderPass,
    vk_framebuffer: []vk.Framebuffer,
    swapchain_metadata: SwapchainMetadata,
    pipeline: vk.Pipeline,
) !void {
    try vkd.beginCommandBuffer(vk_command_buffer, &.{});

    const clear_values = [_]vk.ClearValue{.{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } }};

    vkd.cmdBeginRenderPass(vk_command_buffer, &.{
        .render_pass = vk_render_pass,
        .framebuffer = vk_framebuffer[index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain_metadata.extent,
        },
        .clear_value_count = clear_values.len,
        .p_clear_values = &clear_values,
    }, .@"inline");

    vkd.cmdBindPipeline(vk_command_buffer, .graphics, pipeline);

    vkd.cmdSetViewport(vk_command_buffer, 0, 1, asConstArray(&vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(swapchain_metadata.extent.width),
        .height = @floatFromInt(swapchain_metadata.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }));

    vkd.cmdSetScissor(vk_command_buffer, 0, 1, asConstArray(&vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain_metadata.extent,
    }));

    vkd.cmdDraw(vk_command_buffer, 3, 1, 0, 0);
    vkd.cmdEndRenderPass(vk_command_buffer);
    try vkd.endCommandBuffer(vk_command_buffer);
}

fn drawFrame(
    vkd: DeviceDispatch,
    vk_device: vk.Device,
    sync: *BaseSyncObjects,
    swapchain_metadata: SwapchainMetadata,
    vk_graphic_command_buffer: vk.CommandBuffer,
    vk_render_pass: vk.RenderPass,
    vk_framebuffers: []vk.Framebuffer,
    graphics_pipeline: vk.Pipeline,
    vk_graphics_queue: vk.Queue,
    vk_present_queue: vk.Queue,
) !vk.Result {
    if (try vkd.waitForFences(vk_device, 1, asConstArray(&sync.fen_in_flight[sync.current_index]), vk.TRUE, 1_000_000_000) != .success) {
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

    try vkd.resetCommandBuffer(vk_graphic_command_buffer, .{});

    try recordCommandBuffer(
        vkd,
        vk_graphic_command_buffer,
        next_image_result.image_index,
        vk_render_pass,
        vk_framebuffers,
        swapchain_metadata,
        graphics_pipeline,
    );

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
