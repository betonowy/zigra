const vk = @import("vk");

pub const PfnGetInstanceProcAddr = vk.PfnGetInstanceProcAddr;
pub const PfnGetDeviceProcAddr = vk.PfnGetDeviceProcAddr;

p_create_window_surface: *const fn (self: *const @This(), instance: vk.Instance) anyerror!vk.SurfaceKHR,
p_get_framebuffer_size: *const fn (self: *const @This()) vk.Extent2D,
p_get_required_instance_extensions: *const fn (self: *const @This()) anyerror![][*:0]const u8,
p_wait_events: *const fn (self: *const @This()) void,

pub inline fn createWindowSurface(self: *const @This(), instance: vk.Instance) anyerror!vk.SurfaceKHR {
    return self.p_create_window_surface(self, instance);
}

pub inline fn getFramebufferSize(self: *const @This()) vk.Extent2D {
    return self.p_get_framebuffer_size(self);
}

pub inline fn getRequiredInstanceExtensions(self: *const @This()) anyerror![][*:0]const u8 {
    return self.p_get_required_instance_extensions(self);
}

pub inline fn waitEvents(self: *const @This()) void {
    return self.p_wait_events(self);
}
