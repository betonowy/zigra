const std = @import("std");

const la = @import("la");
const util = @import("util");
const zvk = @import("zvk");

const Ubo = @import("Ubo.zig");

const Pipelines = @import("Pipelines.zig");
const Atlas = @import("Atlas.zig");
const DebugUiData = @import("DebugUiData.zig");
const VertexData = @import("VertexData.zig");

const log = std.log.scoped(.Vulkan_Frame);

device: *zvk.Device,
options: Options,

first_frame: bool = true,

ubo: Ubo,
sampler: zvk.Sampler,

images: Images,
views: Views,
dbs: DrawBuffers,
sets: Sets,
cmds: Cmds,
pools: Pools,
fences: Fences,
semaphores: Semaphores,

pub const Images = struct {
    landscape_encoded: zvk.Image,
    render_world_albedo: zvk.Image,
    render_landscape_albedo: zvk.Image,
    render_landscape_emission: zvk.Image,
    render_landscape_attenuation: zvk.Image,
    render_bkg: zvk.Image,
    render_dui: zvk.Image,
    ldr_im: zvk.Image,
};

pub const Views = struct {
    landscape_encoded: zvk.ImageView,
    render_world_albedo: zvk.ImageView,
    render_landscape_albedo: zvk.ImageView,
    render_landscape_emission: zvk.ImageView,
    render_landscape_attenuation: zvk.ImageView,
    render_bkg: zvk.ImageView,
    render_dui: zvk.ImageView,
    ldr_im: zvk.ImageView,
};

pub const DrawBuffers = struct {
    dui: DebugUiData,
    world: VertexData,
};

pub const Sets = struct {
    render_bkg: zvk.DescriptorSet,
    render_dui: zvk.DescriptorSet,
    render_landscape: zvk.DescriptorSet,
    render_world: zvk.DescriptorSet,
    process_lightmap: zvk.DescriptorSet,
    compose_present: zvk.DescriptorSet,
    compose_intermediate: zvk.DescriptorSet,
};

pub const Cmds = struct {
    gfx_render: zvk.CommandBuffer,
    comp: zvk.CommandBuffer,
    gfx_present: zvk.CommandBuffer,
};

pub const Pools = struct {
    gfx: zvk.CommandPool,
    comp: zvk.CommandPool,
};

pub const Fences = struct {
    gfx_present: zvk.Fence,
};

pub const Semaphores = struct {
    lm_ready: zvk.Semaphore,
    low_render_ready: zvk.Semaphore,
};

pub const Options = struct {
    target_size: @Vector(2, u32),
    lm_margin: @Vector(2, u32),
    window_size: @Vector(2, u32),

    pub fn lmSize(self: @This()) @Vector(2, u32) {
        return self.target_size + self.lm_margin * la.splatT(2, u32, 2);
    }
};

pub fn init(device: *zvk.Device, atlas: Atlas, pipelines: Pipelines, options: Options) !@This() {
    const images = try createImages(device, options);
    errdefer destroyImages(images);

    const views = try createViews(images);
    errdefer destroyViews(views);

    const ubo = try Ubo.init(device);
    errdefer ubo.deinit();

    const dbs = try createDrawBuffers(device);
    errdefer destroyDrawBuffers(dbs);

    const sampler = try zvk.Sampler.init(device, .{});
    errdefer sampler.deinit();

    const sets = try createSets(sampler, views, dbs, ubo, atlas, pipelines);
    errdefer destroySets(sets);

    const pools = try createCommandPools(device);
    errdefer destroyCommandPools(pools);

    const cmds = try createCommandBuffers(pools);
    errdefer destroyCommandBuffers(cmds);

    const fences = try createFences(device);
    errdefer destroyFences(fences);

    const semaphores = try createSemaphores(device);
    errdefer destroySemaphores(semaphores);

    return .{
        .device = device,
        .options = options,
        .ubo = ubo,
        .sampler = sampler,
        .pools = pools,
        .cmds = cmds,
        .fences = fences,
        .semaphores = semaphores,
        .images = images,
        .views = views,
        .sets = sets,
        .dbs = dbs,
    };
}

pub fn deinit(self: @This()) void {
    destroySemaphores(self.semaphores);
    destroyCommandBuffers(self.cmds);
    destroyCommandPools(self.pools);
    destroySets(self.sets);
    destroyDrawBuffers(self.dbs);
    destroyViews(self.views);
    destroyImages(self.images);
    destroyFences(self.fences);
    self.ubo.deinit();
    self.sampler.deinit();
}

pub fn recreateFull(self: *@This(), atlas: Atlas, pipelines: Pipelines, options: Options) !void {
    self.deinit();
    self.* = try init(self.device, atlas, pipelines, options);
}

pub fn recreateSets(self: *@This(), atlas: Atlas, pipelines: Pipelines) !void {
    destroySets(self.sets);
    self.sets = try createSets(self.sampler, self.views, self.dbs, self.ubo, atlas, pipelines);
}

fn destroySets(sets: Sets) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(sets))) |name| {
        @field(sets, name).deinit();
    }
}

fn createSets(
    sampler: zvk.Sampler,
    views: Views,
    dbs: DrawBuffers,
    ubo: Ubo,
    atlas: Atlas,
    pipelines: Pipelines,
) !Sets {
    const render_bkg_ds = try pipelines.render_bkg.createFrameSet(.{
        .sampler = sampler,
        .atlas = atlas,
        .bkg = views.render_bkg,
        .ubo = ubo,
    });
    errdefer render_bkg_ds.deinit();

    const render_landscape_ds = try pipelines.render_landscape.createFrameSet(.{
        .attenuation = views.render_landscape_attenuation,
        .emission = views.render_landscape_emission,
        .encoded = views.landscape_encoded,
        .albedo = views.render_landscape_albedo,
        .ubo = ubo,
    });
    errdefer render_landscape_ds.deinit();

    const compose_intermediate_ds = try pipelines.compose_intermediate.createFrameSet(.{
        .render_landscape_albedo = views.render_landscape_albedo,
        .render_world_albedo = views.render_world_albedo,
        .render_bkg = views.render_bkg,
        .im = views.ldr_im,
        .ubo = ubo,
    });
    errdefer compose_intermediate_ds.deinit();

    const compose_present_ds = try pipelines.compose_present.createFrameSet(.{
        .sampler = sampler,
        .dui = views.render_dui,
        .im = views.ldr_im,
        .ubo = ubo,
    });
    errdefer compose_present_ds.deinit();

    const process_lightmap_ds = try pipelines.process_lightmap.createFrameSet(.{
        .attenuation = views.render_landscape_attenuation,
        .emission = views.render_landscape_emission,
        .ubo = ubo,
    });
    errdefer process_lightmap_ds.deinit();

    const render_dui_ds = try pipelines.render_dui.createFrameSet(.{
        .draw_buffer = dbs.dui.buffer.buffer,
        .sampler = sampler,
        .atlas = atlas,
        .ubo = ubo,
    });
    errdefer render_dui_ds.deinit();

    const render_world_ds = try pipelines.render_world.createFrameSet(.{
        .draw_buffer = dbs.world.buffer.buffer,
        .sampler = sampler,
        .atlas = atlas,
        .ubo = ubo,
    });
    errdefer render_world_ds.deinit();

    return .{
        .render_bkg = render_bkg_ds,
        .render_landscape = render_landscape_ds,
        .compose_intermediate = compose_intermediate_ds,
        .compose_present = compose_present_ds,
        .process_lightmap = process_lightmap_ds,
        .render_dui = render_dui_ds,
        .render_world = render_world_ds,
    };
}

fn destroyImages(images: Images) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(images))) |name| {
        @field(images, name).deinit();
    }
}

fn createImages(device: *zvk.Device, options: Options) !Images {
    const extent_target_image = options.target_size;
    const extent_landscape_image = extent_target_image + la.splatT(2, u32, 2) * options.lm_margin;

    const image_landscape_encoded = blk: {
        var img_options = zvk.Image.InitOptions{
            .extent = la.extend(extent_landscape_image, .{1}),
            .format = .r16_uint,
            .usage = .{ .storage_bit = true },
            .initial_layout = .preinitialized,
            .tiling = .linear,
        };

        // BAR memory does not give advantage at the moment

        img_options.property = .{
            .host_visible_bit = true,
            .device_local_bit = true,
        };

        if (zvk.Image.init(device, img_options)) |img| break :blk img else |_| {}

        img_options.property = .{
            .host_visible_bit = true,
            .host_cached_bit = true,
        };

        if (zvk.Image.init(device, img_options)) |img| break :blk img else |_| {}

        img_options.property = .{
            .host_visible_bit = true,
        };

        break :blk try zvk.Image.init(device, img_options);
    };
    errdefer image_landscape_encoded.deinit();

    const image_render_bkg = try zvk.Image.init(device, .{
        .extent = la.extend(extent_target_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_render_bkg.deinit();

    const image_render_world_albedo = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true, .color_attachment_bit = true },
    });
    errdefer image_render_world_albedo.deinit();

    const image_render_landscape_albedo = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true, .color_attachment_bit = true },
    });
    errdefer image_render_landscape_albedo.deinit();

    const image_render_landscape_emission = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_render_landscape_emission.deinit();

    const image_render_landscape_attenuation = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_render_landscape_attenuation.deinit();

    const image_render_dui = try zvk.Image.init(device, .{
        .extent = la.extend(options.window_size, .{1}),
        .format = .r8g8b8a8_srgb,
        .usage = .{ .color_attachment_bit = true, .sampled_bit = true },
    });
    errdefer image_render_dui.deinit();

    const image_ldr_im = try zvk.Image.init(device, .{
        .extent = la.extend(extent_target_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true, .sampled_bit = true },
    });
    errdefer image_ldr_im.deinit();

    return .{
        .landscape_encoded = image_landscape_encoded,
        .render_bkg = image_render_bkg,
        .render_world_albedo = image_render_world_albedo,
        .render_landscape_albedo = image_render_landscape_albedo,
        .render_landscape_emission = image_render_landscape_emission,
        .render_landscape_attenuation = image_render_landscape_attenuation,
        .render_dui = image_render_dui,
        .ldr_im = image_ldr_im,
    };
}

fn destroyViews(views: Views) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(views))) |name| {
        @field(views, name).deinit();
    }
}

fn createViews(images: Images) !Views {
    const view_landscape_encoded = try zvk.ImageView.init(images.landscape_encoded);
    errdefer view_landscape_encoded.deinit();

    const view_render_bkg = try zvk.ImageView.init(images.render_bkg);
    errdefer view_render_bkg.deinit();

    const view_render_world_albedo = try zvk.ImageView.init(images.render_world_albedo);
    errdefer view_render_world_albedo.deinit();

    const view_render_landscape_albedo = try zvk.ImageView.init(images.render_landscape_albedo);
    errdefer view_render_landscape_albedo.deinit();

    const view_render_landscape_emission = try zvk.ImageView.init(images.render_landscape_emission);
    errdefer view_render_landscape_emission.deinit();

    const view_render_landscape_attenuation = try zvk.ImageView.init(images.render_landscape_attenuation);
    errdefer view_render_landscape_attenuation.deinit();

    const view_render_dui = try zvk.ImageView.init(images.render_dui);
    errdefer view_render_dui.deinit();

    const view_ldr_im = try zvk.ImageView.init(images.ldr_im);
    errdefer view_ldr_im.deinit();

    return .{
        .landscape_encoded = view_landscape_encoded,
        .render_bkg = view_render_bkg,
        .render_world_albedo = view_render_world_albedo,
        .render_landscape_albedo = view_render_landscape_albedo,
        .render_landscape_emission = view_render_landscape_emission,
        .render_landscape_attenuation = view_render_landscape_attenuation,
        .render_dui = view_render_dui,
        .ldr_im = view_ldr_im,
    };
}

fn destroyDrawBuffers(dbs: DrawBuffers) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(dbs))) |name| {
        @field(dbs, name).deinit();
    }
}

fn createDrawBuffers(device: *zvk.Device) !DrawBuffers {
    const dui = try DebugUiData.init(device);
    errdefer dui.deinit();

    const world = try VertexData.init(device);
    errdefer world.deinit();

    return .{
        .dui = dui,
        .world = world,
    };
}

fn destroyCommandPools(pools: Pools) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(pools))) |name| {
        @field(pools, name).deinit();
    }
}

fn createCommandPools(device: *zvk.Device) !Pools {
    const gfx = try zvk.CommandPool.init(device, .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family = device.queue_graphics.family,
    });
    errdefer gfx.deinit();

    const comp = try zvk.CommandPool.init(device, .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family = device.queue_compute.family,
    });
    errdefer comp.deinit();

    return .{
        .gfx = gfx,
        .comp = comp,
    };
}

fn destroyFences(fences: Fences) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(fences))) |name| {
        @field(fences, name).deinit();
    }
}

fn createFences(device: *zvk.Device) !Fences {
    const gfx_present = try zvk.Fence.init(device, true);
    errdefer gfx_present.deinit();

    return .{
        .gfx_present = gfx_present,
    };
}

fn destroyCommandBuffers(cmds: Cmds) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(cmds))) |name| {
        @field(cmds, name).deinit();
    }
}

fn createCommandBuffers(pools: Pools) !Cmds {
    const gfx_render = try zvk.CommandBuffer.init(pools.gfx, .primary);
    errdefer gfx_render.deinit();

    const comp = try zvk.CommandBuffer.init(pools.comp, .primary);
    errdefer comp.deinit();

    const gfx_present = try zvk.CommandBuffer.init(pools.gfx, .primary);
    errdefer gfx_present.deinit();

    return .{
        .gfx_render = gfx_render,
        .comp = comp,
        .gfx_present = gfx_present,
    };
}

fn destroySemaphores(semaphores: Semaphores) void {
    inline for (comptime std.meta.fieldNames(@TypeOf(semaphores))) |name| {
        @field(semaphores, name).deinit();
    }
}

fn createSemaphores(device: *zvk.Device) !Semaphores {
    const lm_ready = try zvk.Semaphore.init(device, .{});
    errdefer lm_ready.deinit();

    const low_render_ready = try zvk.Semaphore.init(device, .{});
    errdefer low_render_ready.deinit();

    return .{
        .lm_ready = lm_ready,
        .low_render_ready = low_render_ready,
    };
}

pub fn begin(self: *@This(), atlas: Atlas, pipelines: Pipelines) !void {
    inline for (comptime std.meta.fieldNames(@TypeOf(self.cmds))) |name| {
        const cmd = @field(self.cmds, name);

        try cmd.reset();
        try cmd.begin(.{ .flags = .{ .one_time_submit_bit = true } });
    }

    var invalidated = false;

    invalidated = try self.dbs.dui.bufferData() or invalidated;
    invalidated = try self.dbs.world.bufferData() or invalidated;

    if (invalidated) try self.recreateSets(atlas, pipelines);

    if (self.first_frame) {
        self.cmds.comp.cmdPipelineBarrier(.{
            .image = &.{
                self.images.landscape_encoded.barrier(.{
                    .src_layout = .preinitialized,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_compute,
                    .dst_queue = self.device.queue_compute,
                }),
                self.images.render_landscape_albedo.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_compute,
                    .dst_queue = self.device.queue_compute,
                }),
                self.images.render_landscape_emission.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_compute,
                    .dst_queue = self.device.queue_compute,
                }),
                self.images.render_landscape_attenuation.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_compute,
                    .dst_queue = self.device.queue_compute,
                }),
            },
        });

        self.cmds.gfx_render.cmdPipelineBarrier(.{
            .image = &.{
                self.images.render_world_albedo.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .color_attachment_optimal,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
                self.images.render_dui.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .color_attachment_optimal,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
                self.images.render_bkg.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
                self.images.ldr_im.barrier(.{
                    .src_layout = .undefined,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
            },
        });

        self.first_frame = false;
    } else {
        self.cmds.gfx_render.cmdPipelineBarrier(.{
            .image = &.{
                self.images.render_world_albedo.barrier(.{
                    .src_layout = .general,
                    .dst_layout = .color_attachment_optimal,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
                self.images.render_dui.barrier(.{
                    .src_layout = .shader_read_only_optimal,
                    .dst_layout = .color_attachment_optimal,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
                self.images.ldr_im.barrier(.{
                    .src_layout = .shader_read_only_optimal,
                    .dst_layout = .general,
                    .src_queue = self.device.queue_graphics,
                    .dst_queue = self.device.queue_graphics,
                }),
            },
        });
    }
}

pub fn end(self: *@This()) !void {
    self.dbs.dui.clear();
    self.dbs.world.clear();

    inline for (comptime std.meta.fieldNames(@TypeOf(self.cmds))) |name| {
        try @field(self.cmds, name).end();
    }

    try self.fences.gfx_present.reset();
}
