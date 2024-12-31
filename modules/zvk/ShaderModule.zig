const vk = @import("vk");

const Device = @import("Device.zig");

device: *Device,
handle: vk.ShaderModule,

pub fn init(device: *Device, code: []const u32) !@This() {
    return .{
        .device = device,
        .handle = try device.api.createShaderModule(device.handle, &.{
            .code_size = code.len * @sizeOf(u32),
            .p_code = code.ptr,
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyShaderModule(self.device.handle, self.handle, null);
}
