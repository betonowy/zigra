const std = @import("std");
const vk = @import("vk");

const Device = @import("Device.zig");

pub const Binding = struct {
    binding: u32,
    count: u32 = 1,
    type: vk.DescriptorType,
    stage_flags: vk.ShaderStageFlags,
};

device: *Device,
handle: vk.DescriptorSetLayout,

pub fn init(device: *Device, bindings: []const Binding) !@This() {
    var vk_bindings = std.BoundedArray(vk.DescriptorSetLayoutBinding, 64){};

    for (bindings) |in| try vk_bindings.append(.{
        .binding = in.binding,
        .descriptor_count = in.count,
        .descriptor_type = in.type,
        .stage_flags = in.stage_flags,
    });

    return .{
        .device = device,
        .handle = try device.api.createDescriptorSetLayout(device.handle, &.{
            .binding_count = @intCast(vk_bindings.len),
            .p_bindings = vk_bindings.constSlice().ptr,
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyDescriptorSetLayout(self.device.handle, self.handle, null);
}
