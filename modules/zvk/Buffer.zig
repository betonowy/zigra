const std = @import("std");
const vk = @import("vk");

const Device = @import("Device.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const Queue = @import("Queue.zig");

pub const InitOptions = struct {
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    sharing_mode: vk.SharingMode = .exclusive,
    properties: vk.MemoryPropertyFlags = .{ .device_local_bit = true },
};

options: InitOptions,
device: *Device,

handle: vk.Buffer,
memory: vk.DeviceMemory,
map: ?[]u8 = null,

pub fn init(device: *Device, info: InitOptions) !@This() {
    const initial_size = info.size;

    const buffer = try device.api.createBuffer(device.handle, &.{
        .size = initial_size,
        .usage = info.usage,
        .sharing_mode = info.sharing_mode,
    }, null);
    errdefer device.api.destroyBuffer(device.handle, buffer, null);

    const memory_requirements = device.bufferMemoryRequirements(buffer);

    const memory = try device.allocateMemory(memory_requirements, info.properties);
    errdefer device.freeMemory(memory);

    try device.bindBufferMemory(buffer, memory);

    return .{
        .options = info,
        .device = device,
        .handle = buffer,
        .memory = memory,
    };
}

pub const CreateStagingBuffer = struct {
    usage: vk.BufferUsageFlags,
};

pub fn createStagingBuffer(self: @This(), options: CreateStagingBuffer) !@This() {
    return init(self.device, .{
        .properties = .{ .host_visible_bit = true },
        .sharing_mode = self.options.sharing_mode,
        .size = self.options.size,
        .usage = options.usage,
    });
}

pub fn mapMemory(self: *@This()) ![]u8 {
    self.unmapMemory();
    const size = self.device.bufferMemoryRequirements(self.handle).size;
    const opt_mapping = try self.device.api.mapMemory(self.device.handle, self.memory, 0, size, .{});
    const mapping = if (opt_mapping) |m| @as([*]u8, @ptrCast(m))[0..size] else return error.NullMapping;
    self.map = mapping;
    return mapping;
}

pub fn unmapMemory(self: *@This()) void {
    if (self.map != null) self.device.api.unmapMemory(self.device.handle, self.memory);
    self.map = null;
}

pub fn deinit(self: @This()) void {
    self.device.freeMemory(self.memory);
    self.device.api.destroyBuffer(self.device.handle, self.handle, null);
}

pub fn resize(self: *@This(), new_size: u64) void {
    self.device.api.unmapMemory(self.device.handle, self.memory);

    const old_memory = self.memory;
    const old_buffer = self.handle;
    defer self.device.api.destroyBuffer(self.device.handle, old_buffer, null);
    defer self.device.freeMemory(old_memory);

    const old_map = try self.mapMemory();

    self.options.size = new_size;
    self.* = self.init(self.device, self.options);

    const new_map = try self.mapMemory();

    const copy_len = @min(new_map.len, old_map.len);
    @memcpy(new_map[0..copy_len], old_map[0..copy_len]);
}

pub fn resizeFast(self: *@This(), new_size: u64) !void {
    self.unmapMemory();
    self.device.freeMemory(self.memory);
    self.device.api.destroyBuffer(self.device.handle, self.handle, null);
    self.options.size = new_size;
    self.* = try init(self.device, self.options);
}

pub fn flush(self: @This(), offset: u64, size: u64) !void {
    _ = self.map orelse return;

    try self.device.api.flushMappedMemoryRanges(self.device.handle, 1, &.{.{
        .memory = self.memory,
        .offset = offset,
        .size = size,
    }});
}

pub const BarrierOptions = struct {
    src_stage_mask: vk.PipelineStageFlags2 = .{},
    src_access_mask: vk.AccessFlags2 = .{},
    dst_stage_mask: vk.PipelineStageFlags2 = .{},
    dst_access_mask: vk.AccessFlags2 = .{},
    offset: ?u64 = null,
    size: ?u64 = null,
    src_queue: Queue,
    dst_queue: Queue,
};

pub fn barrier(self: @This(), options: BarrierOptions) vk.BufferMemoryBarrier2 {
    return vk.BufferMemoryBarrier2{
        .buffer = self.handle,
        .src_stage_mask = options.src_stage_mask,
        .src_access_mask = options.src_access_mask,
        .dst_stage_mask = options.dst_stage_mask,
        .dst_access_mask = options.dst_access_mask,
        .offset = options.offset orelse 0,
        .size = options.size orelse self.options.size,
        .src_queue_family_index = options.src_queue.family.index,
        .dst_queue_family_index = options.dst_queue.family.index,
    };
}

pub const WriteOptions = struct {
    index: u32 = 0,
    binding: u32,
    offset: u64 = 0,
    range: ?u64 = null,
    type: enum { uniform_buffer, storage_buffer },
};

pub fn getDescriptorSetWrite(self: @This(), set: DescriptorSet, options: WriteOptions) DescriptorSet.Write {
    return DescriptorSet.Write{
        .array_element = options.index,
        .binding = options.binding,
        .set = set,
        .type = switch (options.type) {
            .uniform_buffer => .{
                .uniform_buffer = DescriptorSet.Write.Buffers.fromSlice(&.{.{
                    .buffer = self,
                    .offset = options.offset,
                    .range = options.range orelse self.options.size,
                }}) catch unreachable,
            },
            .storage_buffer => .{
                .storage_buffer = DescriptorSet.Write.Buffers.fromSlice(&.{.{
                    .buffer = self,
                    .offset = options.offset,
                    .range = options.range orelse self.options.size,
                }}) catch unreachable,
            },
        },
    };
}
