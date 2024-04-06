const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("./vk.zig");
const stb = @cImport(@cInclude("stb/stb_image.h"));
const Vulkan = @import("./VulkanBackend.zig");
const vk_types = @import("./vulkan_types.zig");

const LandSim = @import("./LandscapeSim.zig");

const Consts = struct {
    const width = 640;
    const height = 480;
};

const GlfwCallbackCtx = struct {
    framebuffer_resized: bool = false,
    cursor_pos: @Vector(2, i32) = std.mem.zeroes(@Vector(2, i32)),
    lbm: bool = false,
    lbm_grab_pos: @Vector(2, i32) = std.mem.zeroes(@Vector(2, i32)),
    lbm_dirty: bool = false,

    const Self = @This();

    fn reset(self: *Self) void {
        self.framebuffer_resized = false;
    }

    fn wasUpdated(self: *Self) bool {
        return self.framebuffer_resized;
    }
};

fn glfwFramebufferSizeCallback(window: glfw.Window, _: u32, _: u32) void {
    var ctx_ptr = window.getUserPointer(GlfwCallbackCtx) orelse @panic("Must return a valid pointer");
    ctx_ptr.framebuffer_resized = true;
}

fn glfwCursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    var ctx_ptr = window.getUserPointer(GlfwCallbackCtx) orelse @panic("Must return a valid pointer");
    ctx_ptr.cursor_pos = .{ @intFromFloat(xpos), @intFromFloat(ypos) };
}

fn glfwMouseCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, _: glfw.Mods) void {
    var ctx_ptr = window.getUserPointer(GlfwCallbackCtx) orelse @panic("Must return a valid pointer");
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

/// Default GLFW error handling callback
fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn run() !void {
    std.log.info("Hello zigra!", .{});

    glfw.setErrorCallback(glfwErrorCallback);

    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return error.GlfwInit;
    }
    defer glfw.terminate();

    const window = glfw.Window.create(Consts.width, Consts.height, "Vulkan window", null, null, .{
        .resizable = false,
        .client_api = .no_api,
    }) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.InitializationFailed;
    };
    defer window.destroy();

    window.setSizeLimits(
        .{ .width = Consts.width, .height = Consts.height },
        .{ .width = null, .height = null },
    );

    window.setAttrib(.resizable, true);

    var glfw_callback_ctx = GlfwCallbackCtx{};
    window.setUserPointer(&glfw_callback_ctx);
    window.setFramebufferSizeCallback(glfwFramebufferSizeCallback);
    window.setCursorPosCallback(glfwCursorPosCallback);
    window.setMouseButtonCallback(glfwMouseCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const WindowCtx = struct {
        window: glfw.Window,
        child: vk_types.WindowCallbacks = .{
            .p_create_window_surface = &createWindowSurface,
            .p_get_framebuffer_size = &getFramebufferSize,
            .p_get_required_instance_extensions = &getRequiredInstanceExtensions,
            .p_wait_events = &waitEvents,
        },

        fn createWindowSurface(child_ptr: *const vk_types.WindowCallbacks, instance: vk.Instance) anyerror!vk.SurfaceKHR {
            const self = @fieldParentPtr(@This(), "child", child_ptr);
            var surface: vk.SurfaceKHR = undefined;

            const result = @as(vk.Result, @enumFromInt(
                glfw.createWindowSurface(instance, self.window, null, &surface),
            ));

            if (result != .success) return error.GlfwCreateWindowSurface;

            return surface;
        }

        fn getFramebufferSize(child_ptr: *const vk_types.WindowCallbacks) vk.Extent2D {
            const self = @fieldParentPtr(@This(), "child", child_ptr);
            const size = self.window.getFramebufferSize();
            return .{ .width = size.width, .height = size.height };
        }

        fn getRequiredInstanceExtensions(_: *const vk_types.WindowCallbacks) anyerror![][*:0]const u8 {
            return glfw.getRequiredInstanceExtensions() orelse blk: {
                const err = glfw.mustGetError();
                std.log.err("Failed to get required vulkan instance extensions: {s}", .{err.description});
                break :blk error.InitializationFailed;
            };
        }

        fn waitEvents(_: *const vk_types.WindowCallbacks) void {
            glfw.waitEvents();
        }
    };

    const window_ctx = WindowCtx{ .window = window };

    var vk_backend = try Vulkan.init(
        allocator,
        @as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)),
        &window_ctx.child,
    );
    defer vk_backend.deinit();

    var ls = try LandSim.init(allocator);
    defer ls.deinit();

    try ls.loadFromPngFile(.{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } }, "land/TEST_LEVEL.png");

    var tick: usize = 0;
    var begin_cam: @Vector(2, i32) = undefined;

    while (!window.shouldClose()) {
        tick += 1;
        glfw.pollEvents();

        if (tick % 5 == 0)
            try ls.simulate();

        try vk_backend.frames[vk_backend.frame_index].landscape.recalculateActiveSets(@intCast(vk_backend.camera_pos));
        const set = vk_backend.frames[vk_backend.frame_index].landscape.active_sets.constSlice();
        vk_backend.frames[vk_backend.frame_index].landscape_upload.resize(0) catch unreachable;

        const extent = @Vector(2, i32){ Vulkan.frame_target_width, Vulkan.frame_target_height };

        const lsExtent = LandSim.NodeExtent{
            .coord = vk_backend.camera_pos - extent / @Vector(2, i32){ 2, 2 },
            .size = .{ Vulkan.frame_target_width, Vulkan.frame_target_height },
        };

        const tc = ls.tileCountForArea(lsExtent);
        std.debug.assert(tc <= 12);

        var tiles: [12]*LandSim.Tile = undefined;
        try ls.ensureArea(lsExtent);
        const used = try ls.fillTilesFromArea(lsExtent, &tiles);

        if (glfw_callback_ctx.lbm_dirty) {
            if (glfw_callback_ctx.lbm) {
                begin_cam = vk_backend.camera_pos;
            }
        }

        if (glfw_callback_ctx.lbm) {
            vk_backend.camera_pos = begin_cam - (glfw_callback_ctx.cursor_pos - glfw_callback_ctx.lbm_grab_pos) / @as(@Vector(2, i32), @splat(2));
        }

        for (used) |src| {
            const min_coord: @Vector(2, f32) = @floatFromInt(src.coord);
            const max_coord: @Vector(2, f32) = @floatFromInt(src.coord + @as(@Vector(2, i32), @splat(LandSim.tile_size - 1)));

            const points = [4]@Vector(2, f32){
                .{ min_coord[0], min_coord[1] },
                .{ min_coord[0], max_coord[1] },
                .{ max_coord[0], min_coord[1] },
                .{ max_coord[0], max_coord[1] },
            };

            const index_pairs = [4]@Vector(2, usize){
                .{ 0, 1 },
                .{ 0, 2 },
                .{ 3, 1 },
                .{ 3, 2 },
            };

            const color: @Vector(4, f16) = switch (src.sleeping) {
                true => .{ 0.0, 1.0, 0.0, 1.0 },
                false => .{ 1.0, 0.0, 0.0, 1.0 },
            };

            for (index_pairs) |index_pair| {
                try vk_backend.scheduleLine(.{ points[index_pair[0]], points[index_pair[1]] }, color, 0, .{ 0.5, 0.5 });
            }

            for (set) |dst| {
                if (@reduce(.Or, src.coord != dst.tile.coord)) continue;

                try vk_backend.frames[vk_backend.frame_index].landscape_upload.append(.{ .tile = dst.tile, .data = std.mem.asBytes(&src.matrix) });
            }
        }

        try vk_backend.process();

        glfw_callback_ctx.lbm_dirty = false;
    }

    std.log.info("vk_backend size: {}", .{@sizeOf(@TypeOf(vk_backend))});
}
