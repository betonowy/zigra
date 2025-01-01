const std = @import("std");

const la = @import("la");
const util = @import("util");
const vk = @import("vk");

const Buffer = @import("Buffer.zig");
const CommandPool = @import("CommandPool.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const Device = @import("Device.zig");
const Event = @import("Event.zig");
const Image = @import("Image.zig");
const ImageView = @import("ImageView.zig");
const Pipeline = @import("Pipeline.zig");
const PipelineLayout = @import("PipelineLayout.zig");

device: *Device,
pool: vk.CommandPool,
handle: vk.CommandBuffer,

pub fn init(pool: CommandPool, level: vk.CommandBufferLevel) !@This() {
    var handle: vk.CommandBuffer = undefined;
    try pool.device.api.allocateCommandBuffers(pool.device.handle, &.{
        .command_buffer_count = 1,
        .command_pool = pool.handle,
        .level = level,
    }, util.meta.asArray(&handle));
    return .{ .device = pool.device, .pool = pool.handle, .handle = handle };
}

pub fn deinit(self: @This()) void {
    self.device.api.freeCommandBuffers(
        self.device.handle,
        self.pool,
        1,
        util.meta.asConstArray(&self.handle),
    );
}

pub fn reset(self: @This()) !void {
    try self.device.api.resetCommandBuffer(self.handle, .{});
}

pub fn begin(self: @This(), info: vk.CommandBufferBeginInfo) !void {
    try self.device.api.beginCommandBuffer(self.handle, &info);
}

pub fn end(self: @This()) !void {
    try self.device.api.endCommandBuffer(self.handle);
}

pub const CmdPipelineBarrier = struct {
    flags: vk.DependencyFlags = .{},
    memory: []const vk.MemoryBarrier2 = &.{},
    buffer: []const vk.BufferMemoryBarrier2 = &.{},
    image: []const vk.ImageMemoryBarrier2 = &.{},
};

pub fn cmdPipelineBarrier(self: @This(), info: CmdPipelineBarrier) void {
    self.device.api.cmdPipelineBarrier2(self.handle, &.{
        .dependency_flags = info.flags,
        .memory_barrier_count = @intCast(info.memory.len),
        .p_memory_barriers = info.memory.ptr,
        .buffer_memory_barrier_count = @intCast(info.buffer.len),
        .p_buffer_memory_barriers = info.buffer.ptr,
        .image_memory_barrier_count = @intCast(info.image.len),
        .p_image_memory_barriers = info.image.ptr,
    });
}

pub const CmdImageCopy = struct {
    src: Image,
    dst: Image,
    src_layout: vk.ImageLayout,
    dst_layout: vk.ImageLayout,
    regions: []const Region = &.{},

    pub const Region = struct {
        src_offset: @Vector(3, i32) = .{ 0, 0, 0 },
        dst_offset: @Vector(3, i32) = .{ 0, 0, 0 },
        extent: ?@Vector(3, u32) = null,
        src_subresource: Layers = .{},
        dst_subresource: Layers = .{},

        pub const Layers = struct {
            aspect_mask: vk.ImageAspectFlags = .{ .color_bit = true },
            mip_level: u32 = 0,
            base_array_layer: u32 = 0,
            layer_count: u32 = vk.REMAINING_ARRAY_LAYERS,
        };
    };
};

pub fn cmdImageCopy(self: @This(), info: CmdImageCopy) !void {
    var image_copy = std.BoundedArray(vk.ImageCopy2, 4){};

    if (info.regions.len == 0) try image_copy.append(.{
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .src_subresource = .{
            .aspect_mask = info.src.options.aspect_mask,
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .dst_subresource = .{
            .aspect_mask = info.src.options.aspect_mask,
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .extent = .{
            .width = info.src.options.extent[0],
            .height = info.src.options.extent[1],
            .depth = 1,
        },
    }) else for (info.regions) |region| {
        const v_extent = region.extent orelse @Vector(3, u32){
            info.src.options.extent[0],
            info.src.options.extent[1],
            1,
        };

        try image_copy.append(.{
            .src_subresource = .{
                .aspect_mask = region.src_subresource.aspect_mask,
                .base_array_layer = region.src_subresource.base_array_layer,
                .mip_level = region.src_subresource.mip_level,
                .layer_count = region.src_subresource.layer_count,
            },
            .dst_subresource = .{
                .aspect_mask = region.dst_subresource.aspect_mask,
                .base_array_layer = region.dst_subresource.base_array_layer,
                .mip_level = region.dst_subresource.mip_level,
                .layer_count = region.dst_subresource.layer_count,
            },
            .extent = .{ .width = v_extent[0], .height = v_extent[1], .depth = v_extent[2] },
            .src_offset = .{
                .x = region.src_offset[0],
                .y = region.src_offset[1],
                .z = region.src_offset[2],
            },
            .dst_offset = .{
                .x = region.dst_offset[0],
                .y = region.dst_offset[1],
                .z = region.dst_offset[2],
            },
        });
    }

    self.device.api.cmdCopyImage2(self.handle, &.{
        .src_image = info.src.handle,
        .dst_image = info.dst.handle,
        .src_image_layout = info.src_layout,
        .dst_image_layout = info.dst_layout,
        .region_count = @intCast(image_copy.len),
        .p_regions = image_copy.constSlice().ptr,
    });
}

pub const CmdBufferCopy = struct {
    src: Buffer,
    dst: Buffer,
    regions: []const Region = &.{},

    pub const Region = struct {
        src_offset: u64,
        dst_offset: u64,
        size: u64,
    };
};

pub fn cmdBufferCopy(self: @This(), info: CmdBufferCopy) !void {
    var regions = std.BoundedArray(vk.BufferCopy2, 64){};

    if (info.regions.len == 0) try regions.append(.{
        .src_offset = 0,
        .dst_offset = 0,
        .size = info.src.options.size,
    });

    for (info.regions) |in| try regions.append(.{
        .src_offset = in.src_offset,
        .dst_offset = in.dst_offset,
        .size = in.size,
    });

    self.device.api.cmdCopyBuffer2(self.handle, &.{
        .src_buffer = info.src.handle,
        .dst_buffer = info.dst.handle,
        .region_count = @intCast(regions.len),
        .p_regions = regions.constSlice().ptr,
    });
}

pub fn cmdBindPipeline(self: @This(), bind: vk.PipelineBindPoint, pipeline: Pipeline) void {
    self.device.api.cmdBindPipeline(self.handle, bind, pipeline.handle);
}

pub fn cmdBindDescriptorSets(
    self: @This(),
    bind: vk.PipelineBindPoint,
    layout: PipelineLayout,
    sets: struct { first: u32 = 0, slice: []const DescriptorSet = &.{} },
    offsets: struct { slice: []const u32 = &.{} },
) !void {
    var out_sets = std.BoundedArray(vk.DescriptorSet, 8){};
    for (sets.slice) |set| try out_sets.append(set.handle);

    self.device.api.cmdBindDescriptorSets(
        self.handle,
        bind,
        layout.handle,
        sets.first,
        @intCast(out_sets.len),
        out_sets.constSlice().ptr,
        @intCast(offsets.slice.len),
        offsets.slice.ptr,
    );
}

pub fn cmdPushConstants(
    self: @This(),
    layout: PipelineLayout,
    stage_flags: vk.ShaderStageFlags,
    data: anytype,
) void {
    self.device.api.cmdPushConstants(
        self.handle,
        layout.handle,
        stage_flags,
        0,
        @sizeOf(@TypeOf(data)),
        &data,
    );
}

pub const CmdDraw = struct {
    vertices: u32 = 0,
    instances: u32 = 0,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub fn cmdDraw(self: @This(), draw: CmdDraw) void {
    self.device.api.cmdDraw(
        self.handle,
        draw.vertices,
        draw.instances,
        draw.first_vertex,
        draw.first_instance,
    );
}

pub const CmdDispatch = struct {
    target_size: @Vector(3, u32),
    local_size: @Vector(3, u32),
};

pub fn cmdDispatch(self: @This(), dispatch: CmdDispatch) void {
    const group_size =
        la.splatT(3, u32, 1) +
        (dispatch.target_size - la.splatT(3, u32, 1)) /
        dispatch.local_size;

    self.device.api.cmdDispatch(self.handle, group_size[0], group_size[1], group_size[2]);
}

pub const RenderingInfo = struct {
    flags: vk.RenderingFlags = .{},
    view_mask: u32 = 0,
    layer_count: u32 = 1,
    render_area: struct {
        offset: @Vector(2, i32) = .{ 0, 0 },
        extent: @Vector(2, u32),
    },
    color_attachments: []const Attachment = &.{},
    depth_attachment: ?Attachment = null,
    stencil_attachment: ?Attachment = null,

    pub const Attachment = struct {
        view: ImageView,
        layout: vk.ImageLayout,
        resolve_mode: vk.ResolveModeFlags = .{},
        resolve_view: ?ImageView = null,
        resolve_layout: vk.ImageLayout = .undefined,
        load_op: vk.AttachmentLoadOp,
        store_op: vk.AttachmentStoreOp,
        clear_value: vk.ClearValue,

        pub fn toVk(self: @This()) vk.RenderingAttachmentInfo {
            return vk.RenderingAttachmentInfo{
                .image_view = self.view.handle,
                .image_layout = self.layout,
                .resolve_mode = self.resolve_mode,
                .resolve_image_view = if (self.resolve_view) |v| v.handle else .null_handle,
                .resolve_image_layout = self.resolve_layout,
                .load_op = self.load_op,
                .store_op = self.store_op,
                .clear_value = self.clear_value,
            };
        }
    };
};

pub fn cmdBeginRendering(self: @This(), in_info: RenderingInfo) !void {
    var color_attachment_info = std.BoundedArray(vk.RenderingAttachmentInfo, 8){};

    for (in_info.color_attachments) |ca| {
        try color_attachment_info.append(ca.toVk());
    }

    self.device.api.cmdBeginRendering(self.handle, &.{
        .color_attachment_count = @intCast(color_attachment_info.len),
        .p_color_attachments = color_attachment_info.constSlice().ptr,
        .p_depth_attachment = if (in_info.depth_attachment) |d| &d.toVk() else null,
        .p_stencil_attachment = if (in_info.stencil_attachment) |s| &s.toVk() else null,
        .render_area = .{
            .offset = .{
                .x = in_info.render_area.offset[0],
                .y = in_info.render_area.offset[1],
            },
            .extent = .{
                .width = in_info.render_area.extent[0],
                .height = in_info.render_area.extent[1],
            },
        },
        .view_mask = in_info.view_mask,
        .layer_count = in_info.layer_count,
    });
}

pub fn cmdEndRendering(self: @This()) void {
    self.device.api.cmdEndRendering(self.handle);
}

pub const Scissor = struct {
    offset: @Vector(2, i32) = .{ 0, 0 },
    size: @Vector(2, u32),
};

pub fn cmdScissor(self: @This(), in: []const Scissor) !void {
    var out = std.BoundedArray(vk.Rect2D, 16){};

    for (in) |s| try out.append(.{
        .extent = .{ .width = s.size[0], .height = s.size[1] },
        .offset = .{ .x = s.offset[0], .y = s.offset[1] },
    });

    self.device.api.cmdSetScissor(self.handle, 0, @intCast(out.len), out.constSlice().ptr);
}

pub const Viewport = struct {
    offset: @Vector(2, f32) = .{ 0, 0 },
    size: @Vector(2, f32),
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub fn cmdViewport(self: @This(), in: []const Viewport) !void {
    var out = std.BoundedArray(vk.Viewport, 16){};

    for (in) |v| try out.append(.{
        .x = v.offset[0],
        .y = v.offset[1],
        .width = v.size[0],
        .height = v.size[1],
        .min_depth = v.min_depth,
        .max_depth = v.max_depth,
    });

    self.device.api.cmdSetViewport(self.handle, 0, @intCast(out.len), out.constSlice().ptr);
}

pub const CmdSetEvent = struct {
    flags: vk.DependencyFlags = .{},
    memory: []const vk.MemoryBarrier2 = &.{},
    buffer: []const vk.BufferMemoryBarrier2 = &.{},
    image: []const vk.ImageMemoryBarrier2 = &.{},
};

pub fn cmdSetEvent(self: @This(), event: Event, info: CmdSetEvent) void {
    self.device.api.cmdSetEvent2(self.handle, event.handle, &.{
        .dependency_flags = info.flags,
        .memory_barrier_count = @intCast(info.memory.len),
        .p_memory_barriers = info.memory.ptr,
        .buffer_memory_barrier_count = @intCast(info.buffer.len),
        .p_buffer_memory_barriers = info.buffer.ptr,
        .image_memory_barrier_count = @intCast(info.image.len),
        .p_image_memory_barriers = info.image.ptr,
    });
}

pub const CmdWaitEvent = struct {
    flags: vk.DependencyFlags = .{},
    memory: []const vk.MemoryBarrier2 = &.{},
    buffer: []const vk.BufferMemoryBarrier2 = &.{},
    image: []const vk.ImageMemoryBarrier2 = &.{},
};

pub fn cmdWaitEvent(self: @This(), event: Event, info: CmdWaitEvent) void {
    self.device.api.cmdWaitEvents2(self.handle, 1, &.{event.handle}, &.{.{
        .dependency_flags = info.flags,
        .memory_barrier_count = @intCast(info.memory.len),
        .p_memory_barriers = info.memory.ptr,
        .buffer_memory_barrier_count = @intCast(info.buffer.len),
        .p_buffer_memory_barriers = info.buffer.ptr,
        .image_memory_barrier_count = @intCast(info.image.len),
        .p_image_memory_barriers = info.image.ptr,
    }});
}
