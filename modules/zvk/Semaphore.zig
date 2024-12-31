const vk = @import("vk");
const Device = @import("Device.zig");

handle: vk.Semaphore,
device: *Device,

pub fn init(device: *Device, flags: vk.SemaphoreCreateFlags) !@This() {
    return .{
        .handle = try device.api.createSemaphore(device.handle, &.{ .flags = flags }, null),
        .device = device,
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroySemaphore(self.device.handle, self.handle, null);
}
