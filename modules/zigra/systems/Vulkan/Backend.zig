const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");
const vk = @import("vk");
const types = @import("Ctx/types.zig");
const initialization = @import("Ctx/init.zig");
const builder = @import("Ctx/builder.zig");
const utils = @import("util");
const push_commands = @import("push_commands.zig");
const VkAllocator = @import("Ctx/VkAllocator.zig");
pub const Atlas = @import("Atlas.zig");
pub const Landscape = @import("Landscape.zig");
pub const SandSim = @import("../World/SandSim.zig");
const Ctx = @import("Ctx.zig");
const Pipelines = @import("Pipelines.zig");
const Landscape2 = @import("Landscape2.zig");

const spv = @import("spv");

const stb = @cImport(@cInclude("stb/stb_image.h"));

const log = std.log.scoped(.Vulkan_backend);

pub const frame_data_count: u8 = 2;
pub const frame_max_draw_commands = 0x100000;
pub const frame_target_width = 320;
pub const frame_target_height = 200;
pub const frame_format = vk.Format.r16g16b16a16_sfloat;

pub const font_file = "images/PhoenixBios_128.png";
pub const font_h_count = 16;
pub const font_height = 8;
pub const font_width = 8;

ctx: *Ctx,

frames: [frame_data_count]FrameData,
frame_index: @TypeOf(frame_data_count) = 0,
pipelines: Pipelines,
atlas: Atlas,

camera_pos: @Vector(2, i32),
start_timestamp: i128,

upload_line_data: std.ArrayListUnmanaged(types.LineData),
upload_triangle_data: std.ArrayListUnmanaged(types.VertexData),
upload_text_data: std.ArrayListUnmanaged(types.TextData),

upload_gui_vertices: std.ArrayListUnmanaged(types.VertexData),
upload_gui_data: std.ArrayListUnmanaged(types.GuiHeader),

font: vk.Rect2D,

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
    draw_point_index: u32 = 0,
    draw_point_range: u32 = 0,
    draw_triangles_index: u32 = 0,
    draw_triangles_range: u32 = 0,
    draw_text_index: u32 = 0,
    draw_text_range: u32 = 0,
    draw_cmd_gui_slice: []types.GuiHeader = &.{},

    command_buffer: vk.CommandBuffer = .null_handle,
};

pub fn init(
    allocator: std.mem.Allocator,
    get_proc_addr: vk.PfnGetInstanceProcAddr,
    window_callbacks: *const types.WindowCallbacks,
) !@This() {
    var self: @This() = undefined;

    self.ctx = try Ctx.init(allocator, get_proc_addr, window_callbacks);
    errdefer self.ctx.deinit();

    self.pipelines = try Pipelines.init(self.ctx);
    errdefer self.pipelines.deinit();

    var l2 = try Landscape2.init(self.ctx);
    defer l2.deinit();

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
        font_file,
    });
    errdefer self.atlas.deinit(&self);

    self.font = self.atlas.getRectByPath(font_file) orelse unreachable;

    try self.createFrameData();
    errdefer self.destroyFrameData();

    self.start_timestamp = std.time.nanoTimestamp();
    self.camera_pos = .{ 0, 0 };

    self.upload_line_data = .{};
    self.upload_triangle_data = .{};
    self.upload_text_data = .{};

    self.upload_gui_vertices = .{};
    self.upload_gui_data = .{};

    return self;
}

pub fn deinit(self: *@This()) void {
    self.ctx.waitIdle();

    self.upload_gui_data.deinit(self.ctx.allocator);
    self.upload_gui_vertices.deinit(self.ctx.allocator);
    self.upload_text_data.deinit(self.ctx.allocator);
    self.upload_triangle_data.deinit(self.ctx.allocator);
    self.upload_line_data.deinit(self.ctx.allocator);

    self.atlas.deinit(self);
    self.destroyFrameData();
    self.pipelines.deinit();

    self.ctx.deinit();
}

pub fn currentFrameData(self: *@This()) *FrameData {
    return &self.frames[self.frame_index];
}

pub fn waitForFreeFrame(self: *@This()) !void {
    if (try self.ctx.vkd.waitForFences(
        self.ctx.device,
        1,
        utils.meta.asConstArray(&self.frames[self.frame_index].fence_busy),
        vk.TRUE,
        1_000_000_000,
    ) != .success) return error.FenceTimeout;
}

pub fn process(self: *@This()) !void {
    try self.ctx.vkd.resetCommandBuffer(self.frames[self.frame_index].command_buffer, .{});
    try self.ctx.vkd.beginCommandBuffer(self.frames[self.frame_index].command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    try self.frames[self.frame_index].landscape.recordUploadData(
        self,
        self.frames[self.frame_index].command_buffer,
        self.frames[self.frame_index].landscape_upload,
    );

    try self.uploadScheduledData(&self.frames[self.frame_index]);

    const next_image = try self.acquireNextSwapchainImage();

    if (next_image.result == .error_out_of_date_khr) {
        try self.ctx.recreateSwapchain();
        return;
    }

    try self.recordDrawFrame(
        self.frames[self.frame_index],
        next_image.image_index,
    );

    const trace_finalize = tracy.traceNamed(@src(), "finalize");
    defer trace_finalize.end();

    try self.ctx.vkd.endCommandBuffer(self.frames[self.frame_index].command_buffer);

    var wait_semaphores = std.BoundedArray(vk.Semaphore, 4){};
    var wait_dst_stage_mask = std.BoundedArray(vk.PipelineStageFlags, 4){};

    try wait_semaphores.append(self.frames[self.frame_index].semaphore_swapchain_image_acquired);
    try wait_dst_stage_mask.append(.{ .color_attachment_output_bit = true });

    std.debug.assert(wait_semaphores.len == wait_dst_stage_mask.len);

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = @intCast(wait_semaphores.len),
        .p_wait_semaphores = wait_semaphores.constSlice().ptr,
        .p_wait_dst_stage_mask = wait_dst_stage_mask.constSlice().ptr,
        .command_buffer_count = 1,
        .p_command_buffers = utils.meta.asConstArray(&self.frames[self.frame_index].command_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = utils.meta.asConstArray(&self.frames[self.frame_index].semaphore_finished),
    };

    try self.ctx.vkd.resetFences(self.ctx.device, 1, utils.meta.asConstArray(&self.frames[self.frame_index].fence_busy));
    try self.ctx.vkd.queueSubmit(self.ctx.graphic_queue, 1, utils.meta.asConstArray(&submit_info), self.frames[self.frame_index].fence_busy);

    const present_result = try self.presentSwapchainImage(
        self.frames[self.frame_index],
        next_image.image_index,
    );

    if (next_image.result != .success or present_result != .success) {
        try self.ctx.recreateSwapchain();
    }

    self.advanceFrame();
}

fn findMemoryType(self: *@This(), type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const props = self.ctx.vki.getPhysicalDeviceMemoryProperties(self.ctx.physical_device);

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

    const buffer = try self.ctx.vkd.createBuffer(self.ctx.device, &.{
        .size = size_in_bytes,
        .usage = info.usage,
        .sharing_mode = info.sharing_mode,
    }, null);
    errdefer self.ctx.vkd.destroyBuffer(self.ctx.device, buffer, null);

    const memory_requirements = self.ctx.vkd.getBufferMemoryRequirements(self.ctx.device, buffer);

    const memory = try self.ctx.vkd.allocateMemory(self.ctx.device, &.{
        .allocation_size = memory_requirements.size,
        .memory_type_index = try self.findMemoryType(memory_requirements.memory_type_bits, info.properties),
    }, null);
    errdefer self.ctx.vkd.freeMemory(self.ctx.device, memory, null);

    try self.ctx.vkd.bindBufferMemory(self.ctx.device, buffer, memory, 0);
    const ptr = try self.ctx.vkd.mapMemory(self.ctx.device, memory, 0, size_in_bytes, .{}) orelse return error.NullMemory;

    return types.BufferVisible(T){
        .handle = buffer,
        .requirements = memory_requirements,
        .memory = memory,
        .map = @as([*]T, @alignCast(@ptrCast(ptr)))[0..info.size],
    };
}

fn destroyBuffer(self: *@This(), typed_buffer: anytype) void {
    self.ctx.vkd.freeMemory(self.ctx.device, typed_buffer.memory, null);
    self.ctx.vkd.destroyBuffer(self.ctx.device, typed_buffer.handle, null);
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
    const image = try self.ctx.vkd.createImage(self.ctx.device, &.{
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
    errdefer self.ctx.vkd.destroyImage(self.ctx.device, image, null);

    const memory_requirements = self.ctx.vkd.getImageMemoryRequirements(self.ctx.device, image);

    const memory = try self.ctx.vkd.allocateMemory(self.ctx.device, &.{
        .allocation_size = memory_requirements.size,
        .memory_type_index = try self.findMemoryType(memory_requirements.memory_type_bits, info.property),
    }, null);
    errdefer self.ctx.vkd.freeMemory(self.ctx.device, memory, null);

    const map = if (info.map_memory) try self.ctx.vkd.mapMemory(self.ctx.device, memory, 0, memory_requirements.size, .{}) else null;

    try self.ctx.vkd.bindImageMemory(self.ctx.device, image, memory, 0);

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

    const view = try self.ctx.vkd.createImageView(self.ctx.device, &.{
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
    if (image_data.view != .null_handle) self.ctx.vkd.destroyImageView(self.ctx.device, image_data.view, null);
    self.ctx.vkd.freeMemory(self.ctx.device, image_data.memory, null);
    self.ctx.vkd.destroyImage(self.ctx.device, image_data.handle, null);
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
            .format = self.pipelines.depth_format,
            .usage = .{ .depth_stencil_attachment_bit = true },
            .property = .{ .device_local_bit = true },
            .aspect_mask = self.pipelines.depth_aspect,
        });

        frame.image_color_sampler = try self.ctx.vkd.createSampler(self.ctx.device, &.{
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

        frame.fence_busy = try self.ctx.vkd.createFence(self.ctx.device, &.{ .flags = .{ .signaled_bit = true } }, null);
        frame.semaphore_finished = try self.ctx.vkd.createSemaphore(self.ctx.device, &.{}, null);
        frame.semaphore_swapchain_image_acquired = try self.ctx.vkd.createSemaphore(self.ctx.device, &.{}, null);

        try self.ctx.vkd.allocateDescriptorSets(self.ctx.device, &.{
            .descriptor_pool = self.ctx.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = utils.meta.asConstArray(&self.pipelines.descriptor_set_layout),
        }, utils.meta.asArray(&frame.descriptor_set));

        try self.ctx.vkd.allocateCommandBuffers(self.ctx.device, &.{
            .command_buffer_count = 1,
            .level = .primary,
            .command_pool = self.ctx.graphic_command_pool,
        }, utils.meta.asArray(&frame.command_buffer));

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
            .p_buffer_info = utils.meta.asConstArray(&ds_ssb_info),
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const write_atlas = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 1,
            .dst_set = frame.descriptor_set,
            .p_image_info = utils.meta.asConstArray(&ds_atlas_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const write_img = vk.WriteDescriptorSet{
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 2,
            .dst_set = frame.descriptor_set,
            .p_image_info = utils.meta.asConstArray(&ds_target_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const write_landscape = vk.WriteDescriptorSet{
            .descriptor_count = ds_landscape_info.len,
            .descriptor_type = .combined_image_sampler,
            .dst_array_element = 0,
            .dst_binding = 3,
            .dst_set = frame.descriptor_set,
            .p_image_info = &ds_landscape_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const writes = [_]vk.WriteDescriptorSet{ write_ssb, write_atlas, write_img, write_landscape };

        self.ctx.vkd.updateDescriptorSets(self.ctx.device, writes.len, &writes, 0, null);
    }
}

fn destroyFrameData(self: *@This()) void {
    for (self.frames[0..]) |*frame| {
        if (frame.command_buffer != .null_handle) {
            self.ctx.vkd.freeCommandBuffers(
                self.ctx.device,
                self.ctx.graphic_command_pool,
                1,
                utils.meta.asConstArray(&frame.command_buffer),
            );
        }

        frame.landscape.deinit(self);

        if (frame.image_color_sampler != .null_handle) self.ctx.vkd.destroySampler(self.ctx.device, frame.image_color_sampler, null);
        if (frame.draw_buffer.handle != .null_handle) self.destroyBuffer(frame.draw_buffer);
        if (frame.image_color.handle != .null_handle) self.destroyImage(frame.image_color);
        if (frame.image_depth.handle != .null_handle) self.destroyImage(frame.image_depth);
        if (frame.fence_busy != .null_handle) self.ctx.vkd.destroyFence(self.ctx.device, frame.fence_busy, null);

        if (frame.semaphore_swapchain_image_acquired != .null_handle) {
            self.ctx.vkd.destroySemaphore(self.ctx.device, frame.semaphore_swapchain_image_acquired, null);
        }

        if (frame.semaphore_finished != .null_handle) {
            self.ctx.vkd.destroySemaphore(self.ctx.device, frame.semaphore_finished, null);
        }
    }
}

fn advanceFrame(self: *@This()) void {
    self.frame_index += 1;
    if (self.frame_index >= frame_data_count) self.frame_index = 0;
}

fn acquireNextSwapchainImage(self: *@This()) !types.DeviceDispatch.AcquireNextImageKHRResult {
    const next_image_result = self.ctx.vkd.acquireNextImageKHR(
        self.ctx.device,
        self.ctx.swapchain.handle,
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
    return self.ctx.vkd.queuePresentKHR(self.ctx.present_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = utils.meta.asConstArray(&frame.semaphore_finished),
        .swapchain_count = 1,
        .p_swapchains = utils.meta.asConstArray(&self.ctx.swapchain.handle),
        .p_image_indices = utils.meta.asConstArray(&swapchain_image_index),
        .p_results = null,
    }) catch |err| {
        switch (err) {
            error.OutOfDateKHR => return .error_out_of_date_khr,
            else => return err,
        }
    };
}

fn recordDrawFrame(self: *@This(), frame: FrameData, swapchain_image_index: u32) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

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

    const push_text = types.TextPushConstant{
        .atlas_size = push.atlas_size,
        .target_size = push.target_size,
        .camera_pos = self.camera_pos,
        .base_stride = 8,
        .stride_len = self.font.extent.width / 8,
        .font_sheet_base = .{
            @intCast(self.font.offset.x),
            @intCast(self.font.offset.y),
        },
    };

    const push_gui = types.BasicPushConstant{
        .atlas_size = .{
            self.atlas.image.extent.width,
            self.atlas.image.extent.height,
        },
        .target_size = .{
            self.ctx.swapchain.extent.width,
            self.ctx.swapchain.extent.height,
        },
        .camera_pos = .{
            @as(i32, @intCast(self.ctx.swapchain.extent.width / 2)),
            @as(i32, @intCast(self.ctx.swapchain.extent.height / 2)),
        },
    };

    {
        const subtrace = tracy.traceNamed(@src(), "Sprite opaque");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.sprite_opaque.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.sprite_opaque.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.image_color.extent.width),
            .height = @floatFromInt(frame.image_color.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = frame.image_color.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.sprite_opaque.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.ctx.vkd.cmdDraw(
            frame.command_buffer,
            4,
            frame.draw_sprite_opaque_range,
            0,
            frame.draw_sprite_opaque_index,
        );
    }
    {
        const subtrace = tracy.traceNamed(@src(), "Line");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.line.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.line.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.image_color.extent.width),
            .height = @floatFromInt(frame.image_color.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = frame.image_color.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.line.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.ctx.vkd.cmdDraw(
            frame.command_buffer,
            2,
            frame.draw_line_range,
            0,
            frame.draw_line_index,
        );
    }
    {
        const subtrace = tracy.traceNamed(@src(), "Point");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.point.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.point.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.image_color.extent.width),
            .height = @floatFromInt(frame.image_color.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = frame.image_color.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.point.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.ctx.vkd.cmdDraw(
            frame.command_buffer,
            frame.draw_point_range,
            1,
            frame.draw_point_index,
            0,
        );
    }
    {
        const subtrace = tracy.traceNamed(@src(), "Landscape");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.landscape.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.landscape.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.image_color.extent.width),
            .height = @floatFromInt(frame.image_color.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = frame.image_color.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.sprite_opaque.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.ctx.vkd.cmdDraw(frame.command_buffer, 4, frame.draw_landscape_range, 0, frame.draw_landscape_index);
    }
    {
        const subtrace = tracy.traceNamed(@src(), "Triangles");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.triangles.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.triangles.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.image_color.extent.width),
            .height = @floatFromInt(frame.image_color.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = frame.image_color.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.triangles.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push)),
            &push,
        );

        self.ctx.vkd.cmdDraw(frame.command_buffer, frame.draw_triangles_range, 1, frame.draw_triangles_index, 0);
    }
    {
        const subtrace = tracy.traceNamed(@src(), "Text");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.text.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.text.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.image_color.extent.width),
            .height = @floatFromInt(frame.image_color.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = frame.image_color.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.text.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push_text)),
            &push_text,
        );

        self.ctx.vkd.cmdDraw(frame.command_buffer, 4, frame.draw_text_range, 0, frame.draw_text_index);
    }

    self.ctx.vkd.cmdEndRendering(frame.command_buffer);
    self.transitionFrameImagesFinal(frame, swapchain_image_index);
    self.beginRenderingFinal(frame, swapchain_image_index);
    {
        const subtrace = tracy.traceNamed(@src(), "Present");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.present.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.present.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        const integer_scaling = integerScaling(self.ctx.swapchain.extent, frame.image_color.extent);

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = @floatFromInt(integer_scaling.offset.x),
            .y = @floatFromInt(integer_scaling.offset.y),
            .width = @floatFromInt(integer_scaling.extent.width),
            .height = @floatFromInt(integer_scaling.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&integer_scaling));

        self.ctx.vkd.cmdDraw(frame.command_buffer, 3, 1, 0, 0);
    }
    {
        const subtrace = tracy.traceNamed(@src(), "GUI");
        defer subtrace.end();

        self.ctx.vkd.cmdBindPipeline(frame.command_buffer, .graphics, self.pipelines.set.gui.handle);

        self.ctx.vkd.cmdBindDescriptorSets(
            frame.command_buffer,
            .graphics,
            self.pipelines.set.gui.layout,
            0,
            1,
            utils.meta.asConstArray(&frame.descriptor_set),
            0,
            null,
        );

        self.ctx.vkd.cmdSetViewport(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.ctx.swapchain.extent.width),
            .height = @floatFromInt(self.ctx.swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }));

        self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.ctx.swapchain.extent,
        }));

        self.ctx.vkd.cmdPushConstants(
            frame.command_buffer,
            self.pipelines.set.gui.layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(@TypeOf(push_gui)),
            &push_gui,
        );

        for (frame.draw_cmd_gui_slice) |cmds| {
            switch (cmds) {
                .scissor => |s_in| {
                    var s = s_in;

                    inline for (0..2) |i| if (s.offset[i] < 0) {
                        s.extent[i] -|= @intCast(-s.offset[i]);
                        s.offset[i] = 0;
                    };

                    self.ctx.vkd.cmdSetScissor(frame.command_buffer, 0, 1, utils.meta.asConstArray(&vk.Rect2D{
                        .offset = .{ .x = s.offset[0], .y = s.offset[1] },
                        .extent = .{ .width = s.extent[0], .height = s.extent[1] },
                    }));
                },
                .triangles => |t| {
                    self.ctx.vkd.cmdDraw(frame.command_buffer, t.end - t.begin, 1, t.begin, 0);
                },
                else => {
                    @panic("Unimplemented");
                },
            }
        }
    }

    self.ctx.vkd.cmdEndRendering(frame.command_buffer);
    self.transitionFrameImagesPresent(frame, swapchain_image_index);
}

fn transitionFrameImagesBegin(self: *@This(), frame: FrameData) void {
    const depth_image_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .fragment_shader_bit = true },
        .src_access_mask = .{ .memory_read_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true },
        .old_layout = .undefined,
        .new_layout = self.pipelines.depth_layout,
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

    self.ctx.vkd.cmdPipelineBarrier2(frame.command_buffer, &.{
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

    self.ctx.vkd.cmdBeginRendering(frame.command_buffer, &.{
        .color_attachment_count = 1,
        .p_color_attachments = utils.meta.asConstArray(&color_attachment),
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
        .image = self.ctx.swapchain.images.get(swapchain_image_index),
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

    self.ctx.vkd.cmdPipelineBarrier2(frame.command_buffer, &.{
        .image_memory_barrier_count = barriers.len,
        .p_image_memory_barriers = &barriers,
    });
}

fn beginRenderingFinal(self: *@This(), frame: FrameData, swapchain_image_index: u32) void {
    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = self.ctx.swapchain.views.get(swapchain_image_index),
        .image_layout = .color_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .clear_value = .{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 0.1 } } },
    };

    self.ctx.vkd.cmdBeginRendering(frame.command_buffer, &.{
        .color_attachment_count = 1,
        .p_color_attachments = utils.meta.asConstArray(&color_attachment),
        .p_depth_attachment = null,
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.ctx.swapchain.extent },
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
        .image = self.ctx.swapchain.images.get(swapchain_image_index),
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

    self.ctx.vkd.cmdPipelineBarrier2(frame.command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = utils.meta.asConstArray(&swapchain_image_barrier),
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
    try self.upload_line_data.append(self.ctx.allocator, .{
        .points = points,
        .color = color,
        .depth = depth,
        .alpha_gradient = alpha,
    });
}

pub fn scheduleVertices(self: *@This(), vertices: []const types.VertexData) !void {
    try self.upload_triangle_data.appendSlice(self.ctx.allocator, vertices);
}

pub fn scheduleVertex(self: *@This(), vertex: types.VertexData) !void {
    try self.upload_triangle_data.append(self.ctx.allocator, vertex);
}

pub inline fn scheduleGuiChar(self: *@This(), data: types.TextData) !void {
    try push_commands.pushGuiChar(self, data);
}

pub inline fn scheduleGuiScissor(self: *@This(), scissor: types.GuiHeader.Scissor) !void {
    return push_commands.pushGuiScissor(self, scissor);
}

pub inline fn scheduleGuiTriangle(self: *@This(), vertices: []const types.VertexData) !void {
    return push_commands.pushGuiTriangle(self, vertices);
}

pub inline fn scheduleGuiLine(self: *@This(), vertices: []const types.VertexData) !void {
    return push_commands.pushGuiLine(self, vertices);
}

fn uploadScheduledData(self: *@This(), frame: *FrameData) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

    var current_index: u32 = 0;

    {
        const subtrace = tracy.traceNamed(@src(), "Landscape");
        defer subtrace.end();

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
        frame.draw_landscape_range = @intCast(self.frames[self.frame_index].landscape.active_sets.len);
        current_index += @intCast(self.frames[self.frame_index].landscape.active_sets.len);

        subtrace.setValue(frame.draw_landscape_range);
    }

    {
        const subtrace = tracy.traceNamed(@src(), "Points");
        defer subtrace.end();

        frame.draw_point_index = current_index;
        frame.draw_point_range = @intCast(self.upload_line_data.items.len * 2);
        {
            const begin = current_index;

            for (0..self.upload_line_data.items.len) |i| {
                const dst_a = &frame.draw_buffer.map[begin + i * 2 + 0];
                const dst_b = &frame.draw_buffer.map[begin + i * 2 + 1];

                dst_a.point = .{
                    .point = .{
                        self.upload_line_data.items[i].points[0][0],
                        self.upload_line_data.items[i].points[0][1],
                        self.upload_line_data.items[i].depth,
                    },
                    .color = self.upload_line_data.items[i].color,
                };

                dst_b.point = .{
                    .point = .{
                        self.upload_line_data.items[i].points[1][0],
                        self.upload_line_data.items[i].points[1][1],
                        self.upload_line_data.items[i].depth,
                    },
                    .color = self.upload_line_data.items[i].color,
                };
            }

            current_index += @intCast(self.upload_line_data.items.len * 2);
        }

        subtrace.setValue(frame.draw_point_range);
    }

    // Draw lines
    {
        const subtrace = tracy.traceNamed(@src(), "Lines");
        defer subtrace.end();

        frame.draw_line_index = current_index;
        frame.draw_line_range = @intCast(self.upload_line_data.items.len);
        {
            const begin = current_index;
            const end = begin + self.upload_line_data.items.len;

            for (self.upload_line_data.items, frame.draw_buffer.map[begin..end]) |src, *dst| dst.line = src;

            current_index += @intCast(self.upload_line_data.items.len);
        }

        self.upload_line_data.clearRetainingCapacity();
        subtrace.setValue(frame.draw_line_range);
    }

    // Draw Triangles
    {
        const subtrace = tracy.traceNamed(@src(), "Triangles");
        defer subtrace.end();

        std.debug.assert(self.upload_triangle_data.items.len % 3 == 0);
        frame.draw_triangles_index = current_index;
        frame.draw_triangles_range = @intCast(self.upload_triangle_data.items.len);
        {
            const begin = current_index;
            const end = begin + self.upload_triangle_data.items.len;

            for (self.upload_triangle_data.items, frame.draw_buffer.map[begin..end]) |src, *dst| dst.vertex = src;

            current_index += @intCast(self.upload_triangle_data.items.len);
        }

        self.upload_triangle_data.clearRetainingCapacity();
        subtrace.setValue(frame.draw_triangles_range);
    }

    // Draw text data
    {
        const subtrace = tracy.traceNamed(@src(), "Text");
        defer subtrace.end();

        frame.draw_text_index = current_index;
        frame.draw_text_range = @intCast(self.upload_text_data.items.len);
        {
            const begin = current_index;
            const end = begin + self.upload_text_data.items.len;

            for (self.upload_text_data.items, frame.draw_buffer.map[begin..end]) |src, *dst| dst.character = src;

            current_index += @intCast(self.upload_text_data.items.len);
        }

        self.upload_text_data.clearRetainingCapacity();
        subtrace.setValue(frame.draw_text_range);
    }

    // Adjust and draw gui data
    {
        const subtrace = tracy.traceNamed(@src(), "GUI Triangles");
        defer subtrace.end();

        for (self.upload_gui_data.items[0..]) |*item| switch (item.*) {
            .triangles => {
                item.triangles.begin += current_index;
                item.triangles.end += current_index;
            },
            else => {},
        };
        {
            const begin = current_index;
            const end = begin + self.upload_gui_vertices.items.len;

            for (self.upload_gui_vertices.items, frame.draw_buffer.map[begin..end]) |src, *dst| dst.vertex = src;

            current_index += @intCast(self.upload_gui_vertices.items.len);
        }

        // Does not deallocate buffer, will not be written until the next frame, so this is ok to do.
        frame.draw_cmd_gui_slice = self.upload_gui_data.items;
        self.upload_gui_data.clearRetainingCapacity();
        self.upload_gui_vertices.clearRetainingCapacity();

        subtrace.setValue(@intCast(frame.draw_cmd_gui_slice.len));
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
