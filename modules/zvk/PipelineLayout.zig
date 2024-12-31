const std = @import("std");
const vk = @import("vk");

const Device = @import("Device.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");

pub const InitOptions = struct {
    flags: vk.PipelineLayoutCreateFlags = .{},
    pcrs: []const vk.PushConstantRange = &.{},
    dsls: []const DescriptorSetLayout,
};

device: *Device,
handle: vk.PipelineLayout,

pub fn init(device: *Device, in: InitOptions) !@This() {
    var out_dsls = std.BoundedArray(vk.DescriptorSetLayout, 64){};

    for (in.dsls) |dsl| try out_dsls.append(dsl.handle);

    return .{
        .device = device,
        .handle = try device.api.createPipelineLayout(device.handle, &.{
            .flags = .{},
            .p_set_layouts = out_dsls.constSlice().ptr,
            .set_layout_count = @intCast(out_dsls.len),
            .p_push_constant_ranges = in.pcrs.ptr,
            .push_constant_range_count = @intCast(in.pcrs.len),
        }, null),
    };
}

pub fn deinit(self: @This()) void {
    self.device.api.destroyPipelineLayout(self.device.handle, self.handle, null);
}
