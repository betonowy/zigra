const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vk");
const util = @import("util");

const vk_api = @import("api.zig");

const Instance = @import("Instance.zig");
const WindowCallbacks = @import("WindowCallbacks.zig");
const VkAllocator = @import("VkAllocator.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const QueueFamily = @import("QueueFamily.zig");
const Device = @import("Device.zig");
const Surface = @import("Surface.zig");
const Semaphore = @import("Semaphore.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const DescriptorPool = @import("DescriptorPool.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
const ImageView = @import("ImageView.zig");

const log = std.log.scoped(.Vulkan_Device);

allocator: std.mem.Allocator,
handle: vk.SwapchainKHR,
instance: *const Instance,
device: *Device,
surface: Surface,
format: vk.Format,
extent: @Vector(2, u32),

graphics_qf: QueueFamily,
present_qf: QueueFamily,

images: []vk.Image,
views: []vk.ImageView,

sem_acquired: []Semaphore,
sem_finished: []Semaphore,

sem_index: u32 = 0,

pub fn init(
    instance: *const Instance,
    pd: PhysicalDevice,
    device: *Device,
    surface: Surface,
    graphics_qf: QueueFamily,
    present_qf: QueueFamily,
) !@This() {
    var arena = std.heap.ArenaAllocator.init(instance.allocator);
    defer arena.deinit();

    const sc_query = try instance.querySwapchainSupport(pd, surface, &arena);

    const surface_format = blk: {
        for (sc_query.formats) |format| {
            if (format.format == vk.Format.b8g8r8a8_srgb and
                format.color_space == vk.ColorSpaceKHR.srgb_nonlinear_khr) break :blk format;
        }

        log.err(
            "Failed to get preferred swapchain format: choosing {s} instead",
            .{@tagName(sc_query.formats[0].format)},
        );

        break :blk sc_query.formats[0];
    };

    const mode = blk: {
        for (sc_query.modes) |mode| {
            if (mode == .fifo_relaxed_khr) break :blk mode;
        }

        break :blk vk.PresentModeKHR.fifo_khr;
    };

    const extent = blk: {
        if (sc_query.capabilities.current_extent.width != std.math.maxInt(u32)) {
            break :blk sc_query.capabilities.current_extent;
        }

        var size = vk.Extent2D{ .height = 0, .width = 0 };

        while (size.width == 0 and size.height == 0) {
            instance.cbs.waitEvents();
            size = instance.cbs.getFramebufferSize();
        }

        try device.waitIdle();

        break :blk vk.Extent2D{
            .width = std.math.clamp(
                size.width,
                sc_query.capabilities.min_image_extent.width,
                sc_query.capabilities.max_image_extent.width,
            ),
            .height = std.math.clamp(
                size.height,
                sc_query.capabilities.min_image_extent.height,
                sc_query.capabilities.max_image_extent.height,
            ),
        };
    };

    var image_count = @max(2, sc_query.capabilities.min_image_count);

    if (sc_query.capabilities.max_image_count > 0) {
        image_count = @min(image_count, sc_query.capabilities.max_image_count);
    }

    const is_one_queue = graphics_qf.index == present_qf.index;
    const indices = [_]u32{ graphics_qf.index, present_qf.index };

    const swapchain = try device.api.createSwapchainKHR(device.handle, &.{
        .surface = surface.handle,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = if (is_one_queue) vk.SharingMode.exclusive else vk.SharingMode.concurrent,
        .queue_family_index_count = if (is_one_queue) 0 else 2,
        .p_queue_family_indices = if (is_one_queue) null else &indices,
        .pre_transform = sc_query.capabilities.current_transform,
        .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
        .present_mode = mode,
        .clipped = vk.TRUE,
    }, null);
    errdefer device.api.destroySwapchainKHR(device.handle, swapchain, null);

    const images = try device.api.getSwapchainImagesAllocKHR(device.handle, swapchain, instance.allocator);
    errdefer instance.allocator.free(images);

    var views = try std.ArrayList(vk.ImageView).initCapacity(instance.allocator, images.len);
    errdefer views.deinit();

    errdefer for (views.items) |view| device.api.destroyImageView(device.handle, view, null);

    for (images) |image| views.appendAssumeCapacity(try device.api.createImageView(device.handle, &.{
        .image = image,
        .view_type = .@"2d",
        .format = surface_format.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .base_mip_level = 0,
            .base_array_layer = 0,
            .level_count = 1,
            .layer_count = 1,
            .aspect_mask = .{ .color_bit = true },
        },
    }, null));

    var sem_acquired = try std.ArrayList(Semaphore).initCapacity(instance.allocator, images.len);
    errdefer sem_acquired.deinit();
    errdefer for (sem_acquired.items) |sem| sem.deinit();

    var sem_finished = try std.ArrayList(Semaphore).initCapacity(instance.allocator, images.len);
    errdefer sem_finished.deinit();
    errdefer for (sem_finished.items) |sem| sem.deinit();

    for (views.items.len) |_| {
        sem_acquired.appendAssumeCapacity(try Semaphore.init(device, .{}));
        sem_finished.appendAssumeCapacity(try Semaphore.init(device, .{}));
    }

    const views_owned = try views.toOwnedSlice();
    errdefer instance.allocator.free(views_owned);
    errdefer for (views_owned) |view| device.api.destroyImageView(device.handle, view, null);

    const sem_acquired_owned = try sem_acquired.toOwnedSlice();
    errdefer instance.allocator.free(sem_acquired_owned);
    errdefer for (sem_acquired_owned) |sem| sem.deinit();

    const sem_finished_owned = try sem_finished.toOwnedSlice();
    errdefer instance.allocator.free(sem_finished_owned);
    errdefer for (sem_finished_owned) |sem| sem.deinit();

    return .{
        .allocator = instance.allocator,
        .handle = swapchain,
        .device = device,
        .format = surface_format.format,
        .extent = .{ extent.width, extent.height },
        .images = images,
        .views = views_owned,
        .sem_acquired = sem_acquired_owned,
        .sem_finished = sem_finished_owned,
        .instance = instance,
        .surface = surface,
        .graphics_qf = graphics_qf,
        .present_qf = present_qf,
    };
}

pub fn deinit(self: @This()) void {
    self.allocator.free(self.images);
    for (self.views) |view| self.device.api.destroyImageView(self.device.handle, view, null);
    for (self.sem_acquired) |sem| sem.deinit();
    for (self.sem_finished) |sem| sem.deinit();
    self.allocator.free(self.views);
    self.allocator.free(self.sem_acquired);
    self.allocator.free(self.sem_finished);
    self.device.api.destroySwapchainKHR(self.device.handle, self.handle, null);
}

pub fn getSemAcq(self: @This()) Semaphore {
    return self.sem_acquired[self.sem_index];
}

pub fn getSemFin(self: @This()) Semaphore {
    return self.sem_finished[self.sem_index];
}

/// Null result means the swapchain is out of date
pub fn acquireNextImage(self: *@This()) !?u32 {
    const old_index = self.sem_index;
    errdefer self.sem_index = old_index;

    self.sem_index += 1;
    if (self.sem_index >= self.images.len) self.sem_index = 0;

    const next_image = self.device.api.acquireNextImageKHR(
        self.device.handle,
        self.handle,
        std.math.maxInt(u64),
        self.getSemAcq().handle,
        .null_handle,
    ) catch |err| {
        switch (err) {
            error.OutOfDateKHR => {
                return null;
            },
            else => return err,
        }
    };

    return next_image.image_index;
}

pub fn present(self: *@This(), image_index: u32) !bool {
    const result = self.device.api.queuePresentKHR(self.device.queue_present.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = util.meta.asConstArray(&self.getSemFin().handle),
        .swapchain_count = 1,
        .p_swapchains = util.meta.asConstArray(&self.handle),
        .p_image_indices = util.meta.asConstArray(&image_index),
        .p_results = null,
    }) catch |err| {
        switch (err) {
            error.OutOfDateKHR => return false,
            else => return err,
        }
    };

    return result == .success;
}

pub fn recreate(self: *@This()) !void {
    self.deinit();

    self.* = try init(
        self.instance,
        self.device.pd,
        self.device,
        self.surface,
        self.graphics_qf,
        self.present_qf,
    );
}

pub fn cmdImageAcquireBarrier(self: *@This(), cmd: CommandBuffer, image_index: u32) void {
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_read_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true },
        .old_layout = .undefined,
        .new_layout = .general,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_array_layer = 0,
            .base_mip_level = 0,
            .layer_count = vk.REMAINING_MIP_LEVELS,
            .level_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = self.device.queue_graphics.family.index,
        .dst_queue_family_index = self.device.queue_graphics.family.index,
        .image = self.images[image_index],
    };

    cmd.cmdPipelineBarrier(.{ .image = &.{barrier} });
}

pub fn cmdImagePresentBarrier(self: *@This(), cmd: CommandBuffer, image_index: u32) void {
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_read_bit = true },
        .old_layout = .general,
        .new_layout = .present_src_khr,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_array_layer = 0,
            .base_mip_level = 0,
            .layer_count = vk.REMAINING_MIP_LEVELS,
            .level_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .src_queue_family_index = self.device.queue_graphics.family.index,
        .dst_queue_family_index = self.device.queue_graphics.family.index,
        .image = self.images[image_index],
    };

    cmd.cmdPipelineBarrier(.{ .image = &.{barrier} });
}
