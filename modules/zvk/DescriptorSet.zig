const std = @import("std");

const vk = @import("vk");
const util = @import("util");

const Device = @import("Device.zig");
const DescriptorPool = @import("DescriptorPool.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const Buffer = @import("Buffer.zig");
const Sampler = @import("Sampler.zig");
const ImageView = @import("ImageView.zig");

pool: DescriptorPool,
handle: vk.DescriptorSet,
can_be_freed: bool,

pub fn init(pool: DescriptorPool, layout: DescriptorSetLayout) !@This() {
    var descriptor_set: vk.DescriptorSet = undefined;

    try pool.device.api.allocateDescriptorSets(pool.device.handle, &.{
        .descriptor_pool = pool.handle,
        .descriptor_set_count = 1,
        .p_set_layouts = util.meta.asConstArray(&layout.handle),
    }, util.meta.asArray(&descriptor_set));

    return .{
        .pool = pool,
        .handle = descriptor_set,
        .can_be_freed = pool.flags.free_descriptor_set_bit,
    };
}

pub fn deinit(self: @This()) void {
    if (!self.can_be_freed) return;

    self.pool.device.api.freeDescriptorSets(
        self.pool.device.handle,
        self.pool.handle,
        1,
        util.meta.asConstArray(&self.handle),
    ) catch @panic("freeDescriptorSets failed");
}

pub const Write = struct {
    set: DescriptorSet,
    binding: u32,
    array_element: u32 = 0,

    type: Union,

    pub const Union = union(vk.DescriptorType) {
        sampler: void,
        combined_image_sampler: Images,
        sampled_image: void,
        storage_image: Images,
        uniform_texel_buffer: void,
        storage_texel_buffer: void,
        uniform_buffer: Buffers,
        storage_buffer: Buffers,
        uniform_buffer_dynamic: void,
        storage_buffer_dynamic: void,
        input_attachment: void,
        inline_uniform_block: void,
        acceleration_structure_khr: void,
        acceleration_structure_nv: void,
        sample_weight_image_qcom: void,
        block_match_image_qcom: void,
        mutable_ext: void,
        partitioned_acceleration_structure_nv: void,
    };

    pub const Images = std.BoundedArray(struct {
        sampler: ?Sampler = null,
        image_view: ImageView,
        image_layout: vk.ImageLayout,
    }, 1);

    pub const Buffers = std.BoundedArray(struct {
        buffer: Buffer,
        offset: ?u64 = null,
        range: ?u64 = null,
    }, 1);
};

pub fn write(self: @This(), ins: []const Write) !void {
    var sf = std.heap.stackFallback(0x4000, self.pool.device.allocator);
    var arena = std.heap.ArenaAllocator.init(sf.get());
    defer arena.deinit();

    const outs = try arena.allocator().alloc(vk.WriteDescriptorSet, ins.len);

    for (ins, outs) |in_write, *out_write| switch (in_write.type) {
        .combined_image_sampler, .storage_image => |in_images| {
            const out_images = try arena.allocator().alloc(vk.DescriptorImageInfo, in_images.len);

            for (in_images.constSlice(), out_images) |in, *out| out.* = .{
                .image_layout = in.image_layout,
                .image_view = in.image_view.handle,
                .sampler = switch (in_write.type) {
                    .combined_image_sampler => in.sampler.?.handle,
                    .storage_image => undefined,
                    else => unreachable,
                },
            };

            out_write.* = .{
                .dst_set = in_write.set.handle,
                .dst_binding = in_write.binding,
                .dst_array_element = in_write.array_element,
                .descriptor_count = @intCast(out_images.len),
                .descriptor_type = in_write.type,
                .p_image_info = out_images.ptr,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        },

        .uniform_buffer, .storage_buffer => |in_buffers| {
            const out_buffers = try arena.allocator().alloc(vk.DescriptorBufferInfo, in_buffers.len);

            for (in_buffers.constSlice(), out_buffers) |in, *out| out.* = .{
                .buffer = in.buffer.handle,
                .offset = in.offset orelse 0,
                .range = in.range orelse in.buffer.options.size,
            };

            out_write.* = .{
                .dst_set = in_write.set.handle,
                .dst_binding = in_write.binding,
                .dst_array_element = in_write.array_element,
                .descriptor_count = @intCast(out_buffers.len),
                .descriptor_type = in_write.type,
                .p_image_info = undefined,
                .p_buffer_info = out_buffers.ptr,
                .p_texel_buffer_view = undefined,
            };
        },

        else => @panic("Unimplemented"),
    };

    self.pool.device.api.updateDescriptorSets(self.pool.device.handle, @intCast(outs.len), outs.ptr, 0, null);
}
