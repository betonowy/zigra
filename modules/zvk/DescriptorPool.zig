const std = @import("std");
const vk = @import("vk");

const Device = @import("Device.zig");

device: *const Device,
handle: vk.DescriptorPool,
flags: vk.DescriptorPoolCreateFlags,

pub const InitOptions = struct {
    max_sets: u32,
    n_combined_image_samplers: u32 = 0,
    n_storage_buffers: u32 = 0,
    n_uniform_buffers: u32 = 0,
    n_storage_images: u32 = 0,
    flags: vk.DescriptorPoolCreateFlags = .{},
};

pub fn init(device: *const Device, options: InitOptions) !@This() {
    var sizes = std.BoundedArray(vk.DescriptorPoolSize, 4){};

    if (options.n_combined_image_samplers > 0) sizes.appendAssumeCapacity(.{
        .type = .combined_image_sampler,
        .descriptor_count = options.n_combined_image_samplers,
    });

    if (options.n_storage_buffers > 0) sizes.appendAssumeCapacity(.{
        .type = .storage_buffer,
        .descriptor_count = options.n_storage_buffers,
    });

    if (options.n_uniform_buffers > 0) sizes.appendAssumeCapacity(.{
        .type = .uniform_buffer,
        .descriptor_count = options.n_uniform_buffers,
    });

    if (options.n_storage_images > 0) sizes.appendAssumeCapacity(.{
        .type = .storage_image,
        .descriptor_count = options.n_storage_images,
    });

    return .{
        .handle = try device.api.createDescriptorPool(device.handle, &.{
            .max_sets = options.max_sets,
            .flags = options.flags,
            .p_pool_sizes = sizes.constSlice().ptr,
            .pool_size_count = @intCast(sizes.len),
        }, null),
        .device = device,
        .flags = options.flags,
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyDescriptorPool(self.device.handle, self.handle, null);
}
