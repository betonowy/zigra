const Device = @import("Device.zig");
const QueueFamily = @import("QueueFamily.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const vk = @import("vk");
const util = @import("util");

device: *Device,
handle: vk.CommandPool,

pub const InitOptions = struct {
    flags: vk.CommandPoolCreateFlags = .{},
    queue_family: QueueFamily,
};

pub fn init(device: *Device, info: InitOptions) !@This() {
    return .{
        .device = device,
        .handle = try device.api.createCommandPool(device.handle, &.{
            .flags = info.flags,
            .queue_family_index = info.queue_family.index,
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyCommandPool(self.device.handle, self.handle, null);
}
