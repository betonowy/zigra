const vk = @import("vk");

const DescriptorSet = @import("DescriptorSet.zig");
const Device = @import("Device.zig");
const Image = @import("Image.zig");
const Sampler = @import("Sampler.zig");

device: *const Device,
handle: vk.ImageView,

pub fn init(image: Image) !@This() {
    return .{
        .device = image.device,
        .handle = try image.device.api.createImageView(image.device.handle, &.{
            .image = image.handle,
            .view_type = if (image.options.array_layers > 1) .@"2d_array" else .@"2d",
            .format = image.options.format,
            .subresource_range = .{
                .aspect_mask = image.options.aspect_mask,
                .base_array_layer = 0,
                .base_mip_level = 0,
                .layer_count = image.options.array_layers,
                .level_count = 1,
            },
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyImageView(self.device.handle, self.handle, null);
}

pub const WriteOptions = struct {
    index: u32 = 0,
    binding: u32,
    layout: vk.ImageLayout,
    sampler: ?Sampler = null,
    type: enum { combined_image_sampler, storage_image },
};

pub fn getDescriptorSetWrite(
    self: @This(),
    set: DescriptorSet,
    options: WriteOptions,
) DescriptorSet.Write {
    return DescriptorSet.Write{
        .array_element = options.index,
        .binding = options.binding,
        .set = set,
        .type = switch (options.type) {
            .combined_image_sampler => .{
                .combined_image_sampler = DescriptorSet.Write.Images.fromSlice(&.{.{
                    .image_layout = options.layout,
                    .image_view = self,
                    .sampler = options.sampler,
                }}) catch unreachable,
            },
            .storage_image => .{
                .storage_image = DescriptorSet.Write.Images.fromSlice(&.{.{
                    .image_layout = options.layout,
                    .image_view = self,
                    .sampler = options.sampler,
                }}) catch unreachable,
            },
        },
    };
}
