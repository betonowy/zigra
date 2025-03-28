const builtin = @import("builtin");
const std = @import("std");

const util = @import("util");
const vk = @import("vk");

const Instance = @import("Instance.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const Queue = @import("Queue.zig");
const QueueFamily = @import("QueueFamily.zig");
const vk_api = @import("api.zig");

const log = std.log.scoped(.Vulkan_Device);

allocator: std.mem.Allocator,
api: vk_api.Device,
handle: vk.Device,
pd: PhysicalDevice,
queue_graphics: Queue,
queue_compute: Queue,
queue_present: Queue,

pub fn init(
    instance: *const Instance,
    pd: PhysicalDevice,
    graphics_qf: QueueFamily,
    compute_qf: QueueFamily,
    present_qf: QueueFamily,
) !*@This() {
    const basic_priority = [_]f32{1.0};

    var queue_create_infos = std.BoundedArray(vk.DeviceQueueCreateInfo, 3){};

    queue_create_infos.appendSliceAssumeCapacity(&.{
        .{
            .queue_family_index = graphics_qf.index,
            .queue_count = 1,
            .p_queue_priorities = &basic_priority,
        },
        .{
            .queue_family_index = compute_qf.index,
            .queue_count = 1,
            .p_queue_priorities = &basic_priority,
        },
    });

    if (present_qf.index != graphics_qf.index) {
        queue_create_infos.appendSliceAssumeCapacity(&.{
            .{
                .queue_family_index = present_qf.index,
                .queue_count = 1,
                .p_queue_priorities = &basic_priority,
            },
        });
    }

    const vulkan_12_features = vk.PhysicalDeviceVulkan12Features{
        .runtime_descriptor_array = vk.TRUE,
    };

    const synchronization_2 = vk.PhysicalDeviceSynchronization2Features{
        .synchronization_2 = vk.TRUE,
        .p_next = @constCast(&vulkan_12_features),
    };

    const dynamic_rendering_feature = vk.PhysicalDeviceDynamicRenderingFeatures{
        .dynamic_rendering = vk.TRUE,
        .p_next = @constCast(&synchronization_2),
    };

    const required_device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

    const device = try instance.vki.createDevice(pd.handle, &.{
        .p_queue_create_infos = queue_create_infos.constSlice().ptr,
        .queue_create_info_count = @intCast(queue_create_infos.len),
        .p_enabled_features = &.{ .sampler_anisotropy = vk.TRUE },
        .enabled_extension_count = @intCast(required_device_extensions.len),
        .pp_enabled_extension_names = &required_device_extensions,
        .enabled_layer_count = @intCast(instance.layers.len),
        .pp_enabled_layer_names = instance.layers.ptr,
        .p_next = &dynamic_rendering_feature,
    }, null);
    errdefer vk_api.Device
        .load(device, instance.vki.dispatch.vkGetDeviceProcAddr.?)
        .destroyDevice(device, null);

    const api = vk_api.Device.load(device, instance.vki.dispatch.vkGetDeviceProcAddr.?);

    const p_self = try instance.allocator.create(@This());

    const queue_graphics = api.getDeviceQueue(device, graphics_qf.index, 0);
    const queue_compute = api.getDeviceQueue(device, compute_qf.index, 0);
    const queue_present = api.getDeviceQueue(device, present_qf.index, 0);

    p_self.* = .{
        .handle = device,
        .api = api,
        .allocator = instance.allocator,
        .pd = pd,
        .queue_graphics = .{ .device = p_self, .family = graphics_qf, .handle = queue_graphics },
        .queue_compute = .{ .device = p_self, .family = compute_qf, .handle = queue_compute },
        .queue_present = .{ .device = p_self, .family = present_qf, .handle = queue_present },
    };

    return p_self;
}

pub fn deinit(self: *@This()) void {
    self.api.destroyDevice(self.handle, null);
    self.allocator.destroy(self);
}

pub fn waitIdle(self: @This()) !void {
    try self.api.deviceWaitIdle(self.handle);
}

pub fn imageMemoryRequirements(self: @This(), image: vk.Image) vk.MemoryRequirements {
    return self.api.getImageMemoryRequirements(self.handle, image);
}

pub fn bufferMemoryRequirements(self: @This(), buffer: vk.Buffer) vk.MemoryRequirements {
    return self.api.getBufferMemoryRequirements(self.handle, buffer);
}

pub fn allocateMemory(self: @This(), req: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.api.allocateMemory(self.handle, &.{
        .allocation_size = req.size,
        .memory_type_index = try self.pd.findMemory(req, flags),
    }, null);
}

pub fn freeMemory(self: @This(), memory: vk.DeviceMemory) void {
    self.api.freeMemory(self.handle, memory, null);
}

pub fn bindImageMemory(self: @This(), image: vk.Image, memory: vk.DeviceMemory) !void {
    try self.api.bindImageMemory(self.handle, image, memory, 0);
}

pub fn bindBufferMemory(self: @This(), buffer: vk.Buffer, memory: vk.DeviceMemory) !void {
    try self.api.bindBufferMemory(self.handle, buffer, memory, 0);
}
