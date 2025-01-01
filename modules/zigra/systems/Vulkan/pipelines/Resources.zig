const std = @import("std");

const la = @import("la");
const spv = @import("spv");
const zvk = @import("zvk");

const Frame = @import("../Frame.zig");

device: *zvk.Device,

set_pool_lm: zvk.DescriptorPool,
set_layout_lm: zvk.DescriptorSetLayout,
set_lm_a: zvk.DescriptorSet,
set_lm_b: zvk.DescriptorSet,
image_lm_a: zvk.Image,
image_lm_b: zvk.Image,
view_lm_a: zvk.ImageView,
view_lm_b: zvk.ImageView,

first_frame: bool = true,

pub fn init(device: *zvk.Device, o: Frame.Options) !@This() {
    const extent_target_image = o.target_size;
    const extent_landscape_image = extent_target_image + la.splatT(2, u32, 2) * o.lm_margin;

    const image_lm_a = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_lm_a.deinit();

    const view_lm_a = try zvk.ImageView.init(image_lm_a);
    errdefer view_lm_a.deinit();

    const image_lm_b = try zvk.Image.init(device, .{
        .extent = la.extend(extent_landscape_image, .{1}),
        .format = .r16g16b16a16_sfloat,
        .usage = .{ .storage_bit = true },
    });
    errdefer image_lm_b.deinit();

    const view_lm_b = try zvk.ImageView.init(image_lm_b);
    errdefer view_lm_b.deinit();

    const pool = try zvk.DescriptorPool.init(device, .{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 2,
        .n_storage_images = 1,
    });
    errdefer pool.deinit();

    const set_layout_lm = try zvk.DescriptorSetLayout.init(device, &.{
        .{
            .binding = 0,
            .stage_flags = .{ .compute_bit = true },
            .type = .storage_image,
        },
    });
    errdefer set_layout_lm.deinit();

    const set_lm_a = try zvk.DescriptorSet.init(pool, set_layout_lm);
    errdefer set_lm_a.deinit();

    try set_lm_a.write(&.{view_lm_a.getDescriptorSetWrite(set_lm_a, .{
        .binding = 0,
        .layout = .general,
        .type = .storage_image,
    })});

    const set_lm_b = try zvk.DescriptorSet.init(pool, set_layout_lm);
    errdefer set_lm_b.deinit();

    try set_lm_b.write(&.{view_lm_b.getDescriptorSetWrite(set_lm_b, .{
        .binding = 0,
        .layout = .general,
        .type = .storage_image,
    })});

    return .{
        .device = device,
        .set_pool_lm = pool,
        .set_layout_lm = set_layout_lm,
        .set_lm_a = set_lm_a,
        .set_lm_b = set_lm_b,
        .image_lm_a = image_lm_a,
        .image_lm_b = image_lm_b,
        .view_lm_a = view_lm_a,
        .view_lm_b = view_lm_b,
    };
}

pub fn deinit(self: @This()) void {
    self.view_lm_a.deinit();
    self.view_lm_b.deinit();
    self.image_lm_a.deinit();
    self.image_lm_b.deinit();
    self.set_lm_a.deinit();
    self.set_lm_b.deinit();
    self.set_layout_lm.deinit();
    self.set_pool_lm.deinit();
}

pub fn cmdPrepare(self: *@This(), frame: *Frame) void {
    if (self.first_frame) self.cmdFirstFrame(frame);
}

fn cmdFirstFrame(self: *@This(), frame: *Frame) void {
    frame.cmds.comp.cmdPipelineBarrier(.{
        .image = &.{
            self.image_lm_a.barrier(.{
                .src_layout = .undefined,
                .dst_layout = .general,
                .src_queue = self.device.queue_compute,
                .dst_queue = self.device.queue_compute,
            }),
            self.image_lm_b.barrier(.{
                .src_layout = .undefined,
                .dst_layout = .general,
                .src_queue = self.device.queue_compute,
                .dst_queue = self.device.queue_compute,
            }),
        },
    });

    self.first_frame = false;
}
