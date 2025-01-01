const vk = @import("vk");

const Device = @import("Device.zig");
const Queue = @import("Queue.zig");

device: *const Device,
options: InitOptions,

handle: vk.Image,
memory: vk.DeviceMemory,
map: ?[]u8 = null,

pub const InitOptions = struct {
    extent: @Vector(3, u32),
    array_layers: u32 = 1,
    format: vk.Format,
    tiling: vk.ImageTiling = .optimal,
    initial_layout: vk.ImageLayout = .undefined,
    usage: vk.ImageUsageFlags,
    sharing_mode: vk.SharingMode = .exclusive,
    flags: vk.ImageCreateFlags = .{},
    property: vk.MemoryPropertyFlags = .{ .device_local_bit = true },
    aspect_mask: vk.ImageAspectFlags = .{ .color_bit = true },
};

pub fn init(device: *const Device, info: InitOptions) !@This() {
    const image = try device.api.createImage(device.handle, &.{
        .image_type = .@"2d",
        .extent = .{
            .width = info.extent[0],
            .height = info.extent[1],
            .depth = info.extent[2],
        },
        .mip_levels = 1,
        .array_layers = info.array_layers,
        .format = info.format,
        .tiling = info.tiling,
        .initial_layout = info.initial_layout,
        .usage = info.usage,
        .sharing_mode = info.sharing_mode,
        .samples = .{ .@"1_bit" = true },
        .flags = info.flags,
    }, null);
    errdefer device.api.destroyImage(device.handle, image, null);

    const memory_requirements = device.imageMemoryRequirements(image);
    const memory = try device.allocateMemory(memory_requirements, info.property);
    errdefer device.freeMemory(memory);

    try device.bindImageMemory(image, memory);

    return .{
        .device = device,
        .options = info,
        .handle = image,
        .memory = memory,
    };
}

pub fn deinit(self: @This()) void {
    self.device.freeMemory(self.memory);
    self.device.api.destroyImage(self.device.handle, self.handle, null);
}

pub const CreateStagingImage = struct {
    layers: ?u32 = null,
    usage: ?vk.ImageUsageFlags = null,
};

pub fn createStagingImage(self: @This(), options: CreateStagingImage) !@This() {
    return init(self.device, .{
        .extent = self.options.extent,
        .array_layers = options.layers orelse self.options.array_layers,
        .format = self.options.format,
        .tiling = .linear,
        .initial_layout = .preinitialized,
        .usage = options.usage orelse .{ .transfer_src_bit = true },
        .flags = self.options.flags,
        .property = .{ .host_visible_bit = true },
        .aspect_mask = self.options.aspect_mask,
    });
}

pub fn mapMemory(self: *@This()) ![]u8 {
    self.unmapMemory();
    const size = self.device.imageMemoryRequirements(self.handle).size;
    const opt_mapping = try self.device.api.mapMemory(self.device.handle, self.memory, 0, size, .{});
    const map = if (opt_mapping) |m| @as([*]u8, @ptrCast(m))[0..size] else return error.NullMapping;
    self.map = map;
    return map;
}

pub fn unmapMemory(self: *@This()) void {
    if (self.map != null) self.device.api.unmapMemory(self.device.handle, self.memory);
    self.map = null;
}

pub const BarrierOptions = struct {
    src_stage_mask: vk.PipelineStageFlags2 = .{},
    src_access_mask: vk.AccessFlags2 = .{},
    dst_stage_mask: vk.PipelineStageFlags2 = .{},
    dst_access_mask: vk.AccessFlags2 = .{},
    src_layout: vk.ImageLayout = .undefined,
    dst_layout: vk.ImageLayout = .undefined,
    subresource_range: Range = .{},
    src_queue: Queue,
    dst_queue: Queue,

    pub const Range = struct {
        aspect_mask: vk.ImageAspectFlags = .{ .color_bit = true },
        base_array_layer: u32 = 0,
        base_mip_level: u32 = 0,
        layer_count: u32 = vk.REMAINING_ARRAY_LAYERS,
        level_count: u32 = vk.REMAINING_MIP_LEVELS,
    };
};

pub fn barrier(self: @This(), options: BarrierOptions) vk.ImageMemoryBarrier2 {
    return .{
        .src_stage_mask = options.src_stage_mask,
        .src_access_mask = options.src_access_mask,
        .dst_stage_mask = options.dst_stage_mask,
        .dst_access_mask = options.dst_access_mask,
        .old_layout = options.src_layout,
        .new_layout = options.dst_layout,
        .subresource_range = .{
            .aspect_mask = options.subresource_range.aspect_mask,
            .base_array_layer = options.subresource_range.base_array_layer,
            .base_mip_level = options.subresource_range.base_mip_level,
            .layer_count = options.subresource_range.layer_count,
            .level_count = options.subresource_range.level_count,
        },
        .src_queue_family_index = options.src_queue.family.index,
        .dst_queue_family_index = options.dst_queue.family.index,
        .image = self.handle,
    };
}
