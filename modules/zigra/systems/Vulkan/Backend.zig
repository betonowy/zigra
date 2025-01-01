const std = @import("std");
const builtin = @import("builtin");

const zvk = @import("zvk");
const util = @import("util");

const Atlas = @import("Atlas.zig");
const Frame = @import("Frame.zig");
const Pipelines = @import("Pipelines.zig");
const shader_io = @import("shader_io.zig");

const log = std.log.scoped(.Vulkan_backend);

pub const frame_len = 2;
pub const frame_target_width = 640;
pub const frame_target_height = 480;
pub const lm_margin_len = 64;

pub const font_file = "images/PhoenixBios_128.png";
pub const font_h_count = 16;
pub const font_height = 8;
pub const font_width = 8;

allocator: std.mem.Allocator,

instance: *zvk.Instance,
physical_device: zvk.PhysicalDevice,
device: *zvk.Device,
surface: zvk.Surface,
swapchain: zvk.Swapchain,

atlas: Atlas,
pipelines: Pipelines,

frames: [frame_len]Frame,
frame_index: u32 = 0,

camera_pos: @Vector(2, i32) = .{ 0, 0 },
camera_pos_diff: @Vector(2, i32) = .{ 0, 0 },

upload_bkg_layers: std.BoundedArray(shader_io.Ubo.Background.Entry, 32) = .{},

pub fn init(
    allocator: std.mem.Allocator,
    get_proc_addr: zvk.WindowCallbacks.PfnGetInstanceProcAddr,
    cbs: *const zvk.WindowCallbacks,
) !@This() {
    const instance = try zvk.Instance.init(allocator, get_proc_addr, cbs, .{
        .options = .{
            .request_debug_utils = switch (builtin.mode) {
                .Debug, .ReleaseSafe => true,
                .ReleaseSmall, .ReleaseFast => false,
            },
            .request_validation = switch (builtin.mode) {
                .Debug, .ReleaseSafe => true,
                .ReleaseSmall, .ReleaseFast => false,
            },
        },
        .vk_allocator = switch (builtin.mode) {
            .Debug, .ReleaseSafe => try zvk.VkAllocator.init(allocator),
            .ReleaseSmall, .ReleaseFast => null,
        },
    });
    errdefer instance.deinit();

    instance.maybeEnableDebugMessenger();

    const surface = try zvk.Surface.init(instance);
    errdefer surface.deinit();

    const physical_device = try instance.pickPhysicalDevice(surface);
    {
        const p = physical_device.properties();
        log.info("Selected: {s}, vendor ID: 0x{x}", .{ p.properties.device_name, p.properties.vendor_id });
    }

    const graphics_queue_family = try physical_device.graphicsQueueFamily();
    const compute_queue_family = try physical_device.computeQueueFamily();
    const present_queue_family = try physical_device.presentQueueFamily(surface);

    const device = try zvk.Device.init(
        instance,
        physical_device,
        graphics_queue_family,
        compute_queue_family,
        present_queue_family,
    );
    errdefer device.deinit();

    // TODO backend should not care about what and how
    //      to load, this should be externally driven.
    var atlas = try Atlas.init(device, &.{
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
    }, .{});
    errdefer atlas.deinit();

    const swapchain = try zvk.Swapchain.init(
        instance,
        physical_device,
        device,
        surface,
        graphics_queue_family,
        present_queue_family,
    );
    errdefer swapchain.deinit();

    // TODO some of these parameters should be runtime configurable
    const frame_options = Frame.Options{
        .lm_margin = .{ lm_margin_len, lm_margin_len },
        .target_size = .{ frame_target_width, frame_target_height },
        .window_size = swapchain.extent,
    };

    const pipelines = try Pipelines.init(device, swapchain, frame_options);
    errdefer pipelines.deinit();

    var frames = std.BoundedArray(Frame, frame_len){};
    errdefer for (frames.constSlice()) |f| f.deinit();

    for (frames.buffer.len) |_| frames.appendAssumeCapacity(
        try Frame.init(device, atlas, pipelines, frame_options),
    );

    return .{
        .allocator = allocator,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .surface = surface,
        .swapchain = swapchain,
        .atlas = atlas,
        .pipelines = pipelines,
        .frames = frames.buffer,
    };
}

pub fn deinit(self: *@This()) void {
    self.device.waitIdle() catch log.err("waitIdle failed", .{});

    for (&self.frames) |frame| frame.deinit();
    self.pipelines.deinit();
    self.atlas.deinit();

    self.swapchain.deinit();
    self.surface.deinit();
    self.device.deinit();
    self.instance.deinit();
}

pub fn currentFrameDataPtr(self: *@This()) *Frame {
    return &self.frames[self.frame_index];
}

pub fn waitForFreeFrame(self: *@This()) !void {
    const fences = self.currentFrameDataPtr().fences;
    try fences.gfx_present.wait();
}

pub fn updateHostData(self: *@This()) void {
    const frame = self.currentFrameDataPtr();
    const ubo = frame.ubo.p_host;

    ubo.camera_diff = self.camera_pos_diff;
    ubo.camera_pos = self.camera_pos;
    ubo.target_size = frame.options.target_size;
    ubo.landscape_size = frame.options.lmSize();
    ubo.window_size = self.swapchain.extent;
    ubo.ambient_color = .{ 1.0, 1.0, 1.0, 1.0 }; // TODO don't hardcode

    const font_ref = self.atlas.getRectIdByPath(font_file).?;
    ubo.dui_font_tex_ref = .{ .index = font_ref.index, .layer = font_ref.layer };

    ubo.background.count = @intCast(self.upload_bkg_layers.len);

    for (
        self.upload_bkg_layers.constSlice(),
        ubo.background.entries[0..self.upload_bkg_layers.len],
    ) |layer, *e| e.* = layer;

    self.upload_bkg_layers.clear();
}

pub fn process(self: *@This()) !void {
    const frame = self.currentFrameDataPtr();

    const swapchain_image_index = try self.swapchain.acquireNextImage() orelse {
        try self.recreateSwapchainAndFrameData();
        return;
    };

    // TODO configure at runtime
    const extra_lm_loops = 5;

    try frame.begin(self.atlas, self.pipelines);

    self.pipelines.resources.cmdPrepare(frame);
    try self.pipelines.render_world.cmdRender(frame);
    try self.pipelines.render_landscape.cmdRender(frame, self.pipelines.resources);
    try self.pipelines.render_bkg.cmdRender(frame);
    try self.pipelines.process_lightmap.cmdRender(frame, self.pipelines.resources, extra_lm_loops);
    try self.pipelines.compose_intermediate.cmdRender(frame, self.pipelines.resources);
    try self.pipelines.render_dui.cmdRender(frame);

    self.swapchain.cmdImageAcquireBarrier(frame.cmds.gfx_present, swapchain_image_index);
    try self.pipelines.compose_present.cmdRender(frame, self.swapchain, swapchain_image_index);
    self.swapchain.cmdImagePresentBarrier(frame.cmds.gfx_present, swapchain_image_index);

    try frame.end();

    try self.device.queue_graphics.submit(.{
        .cmds = &.{frame.cmds.gfx_render},
        .signal = &.{frame.semaphores.low_render_ready},
    });

    try self.device.queue_compute.submit(.{
        .cmds = &.{frame.cmds.comp},
        .signal = &.{frame.semaphores.lm_ready},
    });

    try self.device.queue_graphics.submit(.{
        .cmds = &.{frame.cmds.gfx_present},
        .wait = &.{
            .{
                .sem = self.swapchain.getSemAcq(),
                .stage = .{ .color_attachment_output_bit = true },
            },
            .{
                .sem = frame.semaphores.low_render_ready,
                .stage = .{ .color_attachment_output_bit = true },
            },
            .{
                .sem = frame.semaphores.lm_ready,
                .stage = .{ .compute_shader_bit = true },
            },
        },
        .signal = &.{self.swapchain.getSemFin()},
        .fence = frame.fences.gfx_present,
    });

    if (!try self.swapchain.present(swapchain_image_index)) {
        try self.recreateSwapchainAndFrameData();
    }

    self.advanceFrame();
}

pub fn recreateSwapchainAndFrameData(self: *@This()) !void {
    try self.device.waitIdle();

    try self.swapchain.recreate();

    for (&self.frames) |*frame| {
        try frame.recreateFull(self.atlas, self.pipelines, .{
            .lm_margin = .{ lm_margin_len, lm_margin_len },
            .target_size = .{ frame_target_width, frame_target_height },
            .window_size = self.swapchain.extent,
        });
    }
}

fn advanceFrame(self: *@This()) void {
    self.frame_index += 1;
    if (self.frame_index >= frame_len) self.frame_index = 0;
}
