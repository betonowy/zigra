const std = @import("std");

const la = @import("la");
const util = @import("util");
const zvk = @import("zvk");

const Ubo = @import("Ubo.zig");

const Pipelines = @import("Pipelines.zig");
const Atlas2 = @import("Atlas.zig");
const DebugUiData = @import("DebugUiData.zig");
const VertexData = @import("VertexData.zig");

device: *zvk.Device,
options: Options,

ubo: Ubo,
sampler: zvk.Sampler,
pool: zvk.CommandPool,
cmd: zvk.CommandBuffer,
fence_busy: zvk.Fence,

images: struct {
    landscape_encoded_host: zvk.Image,
    landscape_encoded: zvk.Image,
    render_albedo: zvk.Image,
    render_emission: zvk.Image,
    render_attenuation: zvk.Image,
    render_bkg: zvk.Image,
    // render_depth: zvk.Image,
    // render_ui: zvk.Image,
    render_dui: zvk.Image,
    ldr_im: zvk.Image,
},

views: struct {
    landscape_encoded: zvk.ImageView,
    render_albedo: zvk.ImageView,
    render_emission: zvk.ImageView,
    render_attenuation: zvk.ImageView,
    render_bkg: zvk.ImageView,
    render_dui: zvk.ImageView,
    ldr_im: zvk.ImageView,
},

sets: struct {
    render_bkg: zvk.DescriptorSet,
    render_dui: zvk.DescriptorSet,
    render_landscape: zvk.DescriptorSet,
    render_world: zvk.DescriptorSet,
    process_lightmap: zvk.DescriptorSet,
    compose_present: zvk.DescriptorSet,
    compose_intermediate: zvk.DescriptorSet,
},

dbs: struct {
    dui: DebugUiData,
    world: VertexData,
},

pub const Options = struct {
    target_size: @Vector(2, u32),
    lm_margin: @Vector(2, u32),
    window_size: @Vector(2, u32),

    pub fn lmSize(self: @This()) @Vector(2, u32) {
        return self.target_size + self.lm_margin * la.splatT(2, u32, 2);
    }
};

pub fn init(device: *zvk.Device, atlas: Atlas2, pipelines: Pipelines, options: Options) !@This() {
    const extent_target_image = options.target_size;
    const extent_landscape_image = extent_target_image + la.splatT(2, u32, 2) * options.lm_margin;

    const image_landscape_encoded = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16_uint,
        .usage = .{ .transfer_dst_bit = true, .storage_bit = true },
    });
    errdefer image_landscape_encoded.deinit();

    const view_landscape_encoded = try zvk.ImageView.init(image_landscape_encoded);
    errdefer view_landscape_encoded.deinit();

    const image_landscape_encoded_host = try image_landscape_encoded.createStagingImage(.{});
    errdefer image_landscape_encoded_host.deinit();

    const image_render_bkg = try zvk.Image.init(device, .{
        .extent = la.extend(extent_target_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_render_bkg.deinit();

    const view_render_bkg = try zvk.ImageView.init(image_render_bkg);
    errdefer view_render_bkg.deinit();

    const image_render_albedo = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true, .color_attachment_bit = true },
    });
    errdefer image_render_albedo.deinit();

    const view_render_albedo = try zvk.ImageView.init(image_render_albedo);
    errdefer view_render_albedo.deinit();

    const image_render_emission = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_render_emission.deinit();

    const view_render_emission = try zvk.ImageView.init(image_render_emission);
    errdefer view_render_emission.deinit();

    const image_render_attenuation = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_render_attenuation.deinit();

    const view_render_attenuation = try zvk.ImageView.init(image_render_attenuation);
    errdefer view_render_attenuation.deinit();

    const image_render_dui = try zvk.Image.init(device, .{
        .extent = la.extend(options.window_size, .{1}),
        .format = .r8g8b8a8_srgb,
        .usage = .{ .color_attachment_bit = true, .sampled_bit = true },
    });
    errdefer image_render_dui.deinit();

    const view_render_dui = try zvk.ImageView.init(image_render_dui);
    errdefer view_render_dui.deinit();

    const image_ldr_im = try zvk.Image.init(device, .{
        .extent = la.extend(extent_target_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true, .sampled_bit = true },
    });
    errdefer image_ldr_im.deinit();

    const view_ldr_im = try zvk.ImageView.init(image_ldr_im);
    errdefer view_ldr_im.deinit();

    const ubo = try Ubo.init(device);
    errdefer ubo.deinit();

    const db_dui = try DebugUiData.init(device);
    errdefer db_dui.deinit();

    const db_world = try VertexData.init(device);
    errdefer db_world.deinit();

    const sampler = try zvk.Sampler.init(device, .{});
    errdefer sampler.deinit();

    const render_bkg_ds = try pipelines.render_bkg.createFrameSet(.{
        .sampler = sampler,
        .atlas = atlas,
        .bkg = view_render_bkg,
        .ubo = ubo,
    });
    errdefer render_bkg_ds.deinit();

    const render_landscape_ds = try pipelines.render_landscape.createFrameSet(.{
        .attenuation = view_render_attenuation,
        .emission = view_render_emission,
        .encoded = view_landscape_encoded,
        .albedo = view_render_albedo,
        .ubo = ubo,
    });
    errdefer render_landscape_ds.deinit();

    const compose_intermediate_ds = try pipelines.compose_intermediate.createFrameSet(.{
        .render_albedo = view_render_albedo,
        .render_bkg = view_render_bkg,
        .im = view_ldr_im,
        .ubo = ubo,
    });
    errdefer compose_intermediate_ds.deinit();

    const compose_present_ds = try pipelines.compose_present.createFrameSet(.{
        .sampler = sampler,
        .dui = view_render_dui,
        .im = view_ldr_im,
        .ubo = ubo,
    });
    errdefer compose_present_ds.deinit();

    const process_lightmap_ds = try pipelines.process_lightmap.createFrameSet(.{
        .attenuation = view_render_attenuation,
        .emission = view_render_emission,
        .ubo = ubo,
    });
    errdefer process_lightmap_ds.deinit();

    const render_dui_ds = try pipelines.render_dui.createFrameSet(.{
        .draw_buffer = db_dui.buffer.device_buffer,
        .sampler = sampler,
        .atlas = atlas,
        .ubo = ubo,
    });
    errdefer render_dui_ds.deinit();

    const render_world_ds = try pipelines.render_world.createFrameSet(.{
        .draw_buffer = db_world.buffer.device_buffer,
        .sampler = sampler,
        .atlas = atlas,
        .ubo = ubo,
    });
    errdefer render_world_ds.deinit();

    const pool = try zvk.CommandPool.init(device, .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family = device.queue_gpu_comp.family,
    });
    errdefer pool.deinit();

    const cmd = try zvk.CommandBuffer.init(pool, .primary);
    errdefer cmd.deinit();

    const fence_busy = try zvk.Fence.init(device, true);
    errdefer fence_busy.deinit();

    return .{
        .device = device,
        .options = options,
        .ubo = ubo,
        .sampler = sampler,
        .pool = pool,
        .cmd = cmd,
        .fence_busy = fence_busy,
        .images = .{
            .landscape_encoded = image_landscape_encoded,
            .landscape_encoded_host = image_landscape_encoded_host,
            .render_bkg = image_render_bkg,
            .render_albedo = image_render_albedo,
            .render_emission = image_render_emission,
            .render_attenuation = image_render_attenuation,
            .render_dui = image_render_dui,
            .ldr_im = image_ldr_im,
        },
        .views = .{
            .landscape_encoded = view_landscape_encoded,
            .render_bkg = view_render_bkg,
            .render_albedo = view_render_albedo,
            .render_emission = view_render_emission,
            .render_attenuation = view_render_attenuation,
            .render_dui = view_render_dui,
            .ldr_im = view_ldr_im,
        },
        .sets = .{
            .render_bkg = render_bkg_ds,
            .render_landscape = render_landscape_ds,
            .render_dui = render_dui_ds,
            .render_world = render_world_ds,
            .process_lightmap = process_lightmap_ds,
            .compose_present = compose_present_ds,
            .compose_intermediate = compose_intermediate_ds,
        },
        .dbs = .{
            .dui = db_dui,
            .world = db_world,
        },
    };
}

pub fn deinit(self: @This()) void {
    self.ubo.deinit();
    self.sampler.deinit();
    self.cmd.deinit();
    self.pool.deinit();
    self.fence_busy.deinit();

    inline for (comptime std.meta.fieldNames(@TypeOf(self.images))) |name| {
        @field(self.images, name).deinit();
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(self.views))) |name| {
        @field(self.views, name).deinit();
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(self.sets))) |name| {
        @field(self.sets, name).deinit();
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(self.dbs))) |name| {
        @field(self.dbs, name).deinit();
    }
}

pub fn recreate(self: *@This(), atlas: Atlas2, pipelines: Pipelines, options: Options) !void {
    self.deinit();
    self.* = try init(self.device, atlas, pipelines, options);
}

pub fn end(self: *@This()) void {
    self.dbs.dui.clear();
    self.dbs.world.clear();
}

pub fn cmdBeginFrame(self: *@This()) !void {
    self.cmd.cmdPipelineBarrier(.{
        .image = &.{
            self.images.landscape_encoded_host.barrier(.{
                .dst_access_mask = .{ .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
            self.images.landscape_encoded.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
            self.images.render_bkg.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
            self.images.render_albedo.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
            self.images.render_emission.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
            self.images.render_attenuation.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
            self.images.render_dui.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .fragment_shader_bit = true },
                .src_layout = .undefined,
                .dst_layout = .color_attachment_optimal,
            }),
            self.images.ldr_im.barrier(.{
                .src_access_mask = .{ .shader_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .undefined,
                .dst_layout = .general,
            }),
        },
    });

    try self.cmd.cmdImageCopy(.{
        .src = self.images.landscape_encoded_host,
        .dst = self.images.landscape_encoded,
        .src_layout = .general,
        .dst_layout = .general,
        .regions = &.{.{
            .src_subresource = .{ .layer_count = 1 },
            .dst_subresource = .{ .layer_count = 1 },
        }},
    });

    self.cmd.cmdPipelineBarrier(.{
        .image = &.{
            self.images.landscape_encoded.barrier(.{
                .src_access_mask = .{ .memory_write_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .src_stage_mask = .{ .all_commands_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .src_layout = .general,
                .dst_layout = .general,
            }),
        },
    });

    try self.ubo.cmdUpdateHostToDevice(self.cmd);
    try self.dbs.dui.cmdUpdateHostToDevice(self.cmd);
    try self.dbs.world.cmdUpdateHostToDevice(self.cmd);
}
