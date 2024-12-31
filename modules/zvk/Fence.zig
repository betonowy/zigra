const std = @import("std");

const util = @import("util");
const vk = @import("vk");

const Device = @import("Device.zig");

device: *Device,
handle: vk.Fence,

pub fn init(device: *Device, initial_state: bool) !@This() {
    return .{
        .device = device,
        .handle = try device.api.createFence(device.handle, &.{
            .flags = .{ .signaled_bit = initial_state },
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyFence(self.device.handle, self.handle, null);
}

pub fn wait(self: @This()) !void {
    if (try self.device.api.waitForFences(
        self.device.handle,
        1,
        &.{self.handle},
        vk.TRUE,
        std.math.maxInt(u64),
    ) != .success) {
        return error.FenceFailed;
    }
}

pub fn reset(self: @This()) !void {
    try self.device.api.resetFences(self.device.handle, 1, util.meta.asConstArray(&self.handle));
}
