const std = @import("std");
const vk = @import("vk");
const utils = @import("util");
const Impl = utils.CLikeAllocator;

cbs: vk.AllocationCallbacks,

pub fn init(allocator: std.mem.Allocator) !@This() {
    const user_data = try allocator.create(Impl);
    errdefer allocator.destroy(user_data);
    user_data.allocator = allocator;

    return @This(){ .cbs = .{
        .p_user_data = user_data,
        .pfn_allocation = &vkAllocation,
        .pfn_reallocation = &vkReallocation,
        .pfn_free = &vkFree,
    } };
}

pub fn deinit(self: *@This()) void {
    const user_data = Impl.castFromPtr(self.cbs.p_user_data orelse unreachable);
    user_data.allocator.destroy(user_data);
}

fn vkAllocation(ud: ?*anyopaque, size: usize, alignment: usize, _: vk.SystemAllocationScope) callconv(.C) ?*anyopaque {
    return Impl.castFromPtr(ud orelse unreachable).allocAlign(size, alignment) catch null;
}

fn vkReallocation(ud: ?*anyopaque, prev_opt: ?*anyopaque, size: usize, alignment: usize, _: vk.SystemAllocationScope) callconv(.C) ?*anyopaque {
    const impl = Impl.castFromPtr(ud orelse unreachable);

    if (prev_opt) |prev| {
        if (size != 0) return impl.reallocAlign(prev, size, alignment) catch null else impl.free(prev);
    } else {
        if (size != 0) return impl.allocAlign(size, alignment) catch null;
    }

    return null;
}

fn vkFree(ud: ?*anyopaque, memory: ?*anyopaque) callconv(.C) void {
    Impl.castFromPtr(ud orelse unreachable).free(memory orelse return);
}
