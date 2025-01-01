const vk = @import("vk");

const Device = @import("Device.zig");

device: *Device,
handle: vk.Event,

pub fn init(device: *Device) !@This() {
    return .{
        .device = device,
        .handle = try device.api.createEvent(device.handle, &.{
            .flags = .{ .device_only_bit = true },
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyEvent(self.device.handle, self.handle, null);
}
