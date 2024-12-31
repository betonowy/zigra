const vk = @import("vk");

const Device = @import("Device.zig");

device: *Device,
handle: vk.Sampler,
options: InitOptions,

pub const InitOptions = struct {
    mag_filter: vk.Filter = .nearest,
    min_filter: vk.Filter = .nearest,
    mipmap: ?struct {
        mode: vk.SamplerMipmapMode = .nearest,
        lod_bias: f32,
        lod_min: f32,
        lod_max: f32,
    } = null,
    address_mode: vk.SamplerAddressMode = .clamp_to_edge,
    anisotropy: ?f32 = null,
    compare_op: ?vk.CompareOp = null,
    border_color: vk.BorderColor = .int_transparent_black,
    unnormalized_coordinates: bool = false,
};

pub fn init(device: *Device, o: InitOptions) !@This() {
    return .{
        .device = device,
        .options = o,
        .handle = try device.api.createSampler(device.handle, &.{
            .mag_filter = o.mag_filter,
            .min_filter = o.min_filter,
            .address_mode_u = o.address_mode,
            .address_mode_v = o.address_mode,
            .address_mode_w = o.address_mode,
            .anisotropy_enable = if (o.anisotropy != null) vk.TRUE else vk.FALSE,
            .max_anisotropy = o.anisotropy orelse undefined,
            .border_color = o.border_color,
            .unnormalized_coordinates = if (o.unnormalized_coordinates) vk.TRUE else vk.FALSE,
            .compare_enable = if (o.compare_op != null) vk.TRUE else vk.FALSE,
            .compare_op = o.compare_op orelse undefined,
            .mipmap_mode = if (o.mipmap) |m| m.mode else .nearest,
            .mip_lod_bias = if (o.mipmap) |m| m.lod_bias else 0,
            .min_lod = if (o.mipmap) |m| m.lod_min else 0,
            .max_lod = if (o.mipmap) |m| m.lod_max else 0,
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroySampler(self.device.handle, self.handle, null);
}
