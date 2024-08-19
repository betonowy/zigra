const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const lifetime = @import("lifetime");
const Vulkan = @import("Vulkan.zig");

const Consts = struct {
    const init_window_w = 640;
    const init_window_h = 480;
};

var s_initialized = false;

allocator: std.mem.Allocator,
window: glfw.Window,

cbs_ctx_glfw: GlfwCbCtx = .{},
cbs_vulkan: Vulkan.WindowCallbacks = .{
    .p_create_window_surface = &vkCbCreateWindowSurface,
    .p_get_framebuffer_size = &vkCbGetFramebufferSize,
    .p_get_required_instance_extensions = &vkCbGetRequiredInstanceExtensions,
    .p_wait_events = &vkCbWaitEvents,
},

quit_requested: bool = false,

pub fn init(allocator: std.mem.Allocator) !@This() {
    if (s_initialized) @panic("This system can only have at most a single instance at any time!");

    glfw.setErrorCallback(glfwCbError);

    if (!glfw.init(.{})) std.log.err("GLFW failed to initialize!: {s}", .{glfw.getErrorString() orelse ""});

    const window = glfw.Window.create(Consts.init_window_w, Consts.init_window_h, "Vulkan window", null, null, .{
        .resizable = false,
        .client_api = .no_api,
    }) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.InitializationFailed;
    };

    window.setSizeLimits(
        .{ .width = Consts.init_window_w, .height = Consts.init_window_h },
        .{ .width = null, .height = null },
    );

    window.setAttrib(.resizable, true);

    s_initialized = true;

    return .{ .allocator = allocator, .window = window };
}

pub fn systemInit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.window.setUserPointer(&self.cbs_ctx_glfw);
    self.window.setCursorPosCallback(glfwCbCursorPos);
    self.window.setMouseButtonCallback(glfwCbMouse);
    self.window.setCharCallback(glfwCbChar);
    self.window.setKeyCallback(glfwCbKey);
    self.window.setScrollCallback(glfwCbScroll);
}

pub fn systemDeinit(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn deinit(self: *@This()) void {
    glfw.terminate();
    s_initialized = false;
    self.* = undefined;
}

pub const GlfwCbCtx = struct {
    cursor_pos: @Vector(2, i32) = std.mem.zeroes(@Vector(2, i32)),

    lbm: bool = false,
    lbm_grab_pos: @Vector(2, i32) = std.mem.zeroes(@Vector(2, i32)),
    lbm_dirty: bool = false,

    x_scroll: f32 = 0,
    y_scroll: f32 = 0,

    const Self = @This();
};

fn glfwCbCursorPos(window: glfw.Window, xpos: f64, ypos: f64) void {
    var ctx_ptr = window.getUserPointer(GlfwCbCtx) orelse unreachable;
    ctx_ptr.cursor_pos = .{ @intFromFloat(xpos), @intFromFloat(ypos) };
}

fn glfwCbMouse(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, _: glfw.Mods) void {
    var ctx_ptr = window.getUserPointer(GlfwCbCtx) orelse unreachable;
    switch (button) {
        .left => {
            ctx_ptr.lbm_dirty = true;
            switch (action) {
                .press => {
                    ctx_ptr.lbm = true;
                    ctx_ptr.lbm_grab_pos = ctx_ptr.cursor_pos;
                },
                .release => ctx_ptr.lbm = false,
                .repeat => ctx_ptr.lbm = true,
            }
        },
        else => {},
    }
}

fn glfwCbChar(window: glfw.Window, codepoint: u21) void {
    const ctx_ptr = window.getUserPointer(GlfwCbCtx) orelse unreachable;
    _ = ctx_ptr; // autofix
    std.debug.print("codepoint: {}\n", .{codepoint});
}

fn glfwCbKey(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    std.debug.print(
        "Key: {s}, scancode: {}, action: {s}, mods: {}\n",
        .{ @tagName(key), scancode, @tagName(action), mods },
    );
    _ = window; // autofix
}

fn glfwCbScroll(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    var ctx_ptr = window.getUserPointer(GlfwCbCtx) orelse unreachable;
    ctx_ptr.x_scroll += @floatCast(xoffset);
    ctx_ptr.y_scroll += @floatCast(yoffset);
}

fn glfwCbError(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

fn vkCbCreateWindowSurface(child_ptr: *const Vulkan.WindowCallbacks, instance: Vulkan.vk.Instance) anyerror!Vulkan.vk.SurfaceKHR {
    const self: *const @This() = @fieldParentPtr("cbs_vulkan", child_ptr);
    var surface: Vulkan.vk.SurfaceKHR = undefined;

    const result = @as(Vulkan.vk.Result, @enumFromInt(
        glfw.createWindowSurface(instance, self.window, null, &surface),
    ));

    if (result != .success) return error.GlfwCreateWindowSurface;

    return surface;
}

fn vkCbGetFramebufferSize(child_ptr: *const Vulkan.WindowCallbacks) Vulkan.vk.Extent2D {
    const self: *const @This() = @fieldParentPtr("cbs_vulkan", child_ptr);
    const size = self.window.getFramebufferSize();
    return .{ .width = size.width, .height = size.height };
}

fn vkCbGetRequiredInstanceExtensions(_: *const Vulkan.WindowCallbacks) anyerror![][*:0]const u8 {
    return glfw.getRequiredInstanceExtensions() orelse blk: {
        const err = glfw.mustGetError();
        std.log.err("Failed to get required vulkan instance extensions: {s}", .{err.description});
        break :blk error.InitializationFailed;
    };
}

fn vkCbWaitEvents(_: *const Vulkan.WindowCallbacks) void {
    glfw.waitEvents();
}

pub fn pfnGetInstanceProcAddress(_: *@This()) *const @TypeOf(glfw.getInstanceProcAddress) {
    return &glfw.getInstanceProcAddress;
}

pub fn process(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    glfw.pollEvents();
    self.quit_requested = self.window.shouldClose();
}
