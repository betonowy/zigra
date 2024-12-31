const vk = @import("vk");

const Instance = @import("Instance.zig");

instance: *Instance,
handle: vk.SurfaceKHR,

pub fn init(instance: *Instance) !@This() {
    return .{
        .handle = try instance.cbs.createWindowSurface(instance.handle),
        .instance = instance,
    };
}

pub fn deinit(self: @This()) void {
    self.instance.vki.destroySurfaceKHR(self.instance.handle, self.handle, null);
}
