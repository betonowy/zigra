const std = @import("std");
const vk = @import("vk");

const Device = @import("Device.zig");
const Fence = @import("Fence.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const QueueFamily = @import("QueueFamily.zig");
const Semaphore = @import("Semaphore.zig");

device: *const Device,
handle: vk.Queue,
family: QueueFamily,

pub const Submit = struct {
    fence: ?Fence = null,
    cmds: []const CommandBuffer = &.{},
    signal: []const Semaphore = &.{},
    wait: []const struct {
        sem: Semaphore,
        stage: vk.PipelineStageFlags = .{ .all_commands_bit = true },
    } = &.{},
};

pub fn submit(self: @This(), info: Submit) !void {
    var signal_semaphores = std.BoundedArray(vk.Semaphore, 8){};
    var wait_semaphores = std.BoundedArray(vk.Semaphore, 8){};
    var wait_stages = std.BoundedArray(vk.PipelineStageFlags, 8){};
    var cmds = std.BoundedArray(vk.CommandBuffer, 8){};

    for (info.cmds) |cmd| try cmds.append(cmd.handle);

    for (info.signal) |s| try signal_semaphores.append(s.handle);

    for (info.wait) |w| {
        try wait_semaphores.append(w.sem.handle);
        try wait_stages.append(w.stage);
    }

    try self.device.api.queueSubmit(self.handle, 1, &.{.{
        .command_buffer_count = @intCast(cmds.len),
        .p_command_buffers = cmds.constSlice().ptr,
        .signal_semaphore_count = @intCast(signal_semaphores.len),
        .p_signal_semaphores = signal_semaphores.constSlice().ptr,
        .wait_semaphore_count = @intCast(wait_semaphores.len),
        .p_wait_semaphores = wait_semaphores.constSlice().ptr,
        .p_wait_dst_stage_mask = wait_stages.constSlice().ptr,
    }}, if (info.fence) |f| f.handle else .null_handle);
}
