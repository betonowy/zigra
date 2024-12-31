const std = @import("std");
const vk = @import("vk");
const vk_api = @import("api.zig");

const QueueFamily = @import("QueueFamily.zig");
const Device = @import("Device.zig");
const Surface = @import("Surface.zig");

allocator: std.mem.Allocator,
handle: vk.PhysicalDevice,
vki: *const vk_api.Instance,

pub fn properties(self: @This()) vk.PhysicalDeviceProperties2 {
    var props: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
    self.vki.getPhysicalDeviceProperties2(self.handle, &props);
    return props;
}

pub fn graphicsComputeQueueFamily(self: @This()) !QueueFamily {
    var index_count: u32 = undefined;

    self.vki.getPhysicalDeviceQueueFamilyProperties(self.handle, &index_count, null);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const queue_families = try arena.allocator().alloc(vk.QueueFamilyProperties, index_count);
    self.vki.getPhysicalDeviceQueueFamilyProperties(self.handle, &index_count, queue_families.ptr);

    for (queue_families, 0..) |queue_family, i| {
        if (queue_family.queue_flags.graphics_bit and queue_family.queue_flags.compute_bit) {
            return .{ .index = @intCast(i), .flags = queue_family.queue_flags };
        }
    }

    return error.QueueFamilyNotFound;
}

pub fn presentQueueFamily(self: @This(), surface: Surface) !QueueFamily {
    var index_count: u32 = undefined;

    self.vki.getPhysicalDeviceQueueFamilyProperties(self.handle, &index_count, null);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const queue_families = try arena.allocator().alloc(vk.QueueFamilyProperties, index_count);
    self.vki.getPhysicalDeviceQueueFamilyProperties(self.handle, &index_count, queue_families.ptr);

    for (queue_families, 0..) |queue_family, i| {
        if (try self.vki.getPhysicalDeviceSurfaceSupportKHR(self.handle, @intCast(i), surface.handle) == vk.TRUE) {
            return .{ .index = @intCast(i), .flags = queue_family.queue_flags };
        }
    }

    return error.QueueFamilyNotFound;
}

pub fn findMemory(
    self: @This(),
    req: vk.MemoryRequirements,
    flags: vk.MemoryPropertyFlags,
) !u32 {
    const props = self.vki.getPhysicalDeviceMemoryProperties(self.handle);

    for (props.memory_types[0..props.memory_type_count], 0..) |prop, i| {
        const prop_match = prop.property_flags.contains(flags);
        const type_match = req.memory_type_bits & @as(u32, 1) << @intCast(i) != 0;
        if (type_match and prop_match) return @intCast(i);
    }

    return error.MemoryTypeNotFound;
}
