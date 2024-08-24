const std = @import("std");

const Backend = @import("Vulkan/Backend.zig");
const types = @import("Vulkan/types.zig");

const lifetime = @import("lifetime");
const tracy = @import("tracy");
const utils = @import("utils");
const zigra = @import("../root.zig");

pub const vk = @import("vk");
pub const WindowCallbacks = types.WindowCallbacks;

allocator: std.mem.Allocator,
impl: Backend,

wg_process: std.Thread.WaitGroup,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .impl = undefined,
        .wg_process = std.Thread.WaitGroup{},
    };
}

pub fn systemInit(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    self.impl = try Backend.init(
        self.allocator,
        @as(vk.PfnGetInstanceProcAddr, @ptrCast(ctx.systems.window.pfnGetInstanceProcAddress())),
        &ctx.systems.window.cbs_vulkan,
    );
}

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.wg_process.wait();
    self.wg_process.reset();
    self.impl.deinit();
}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn waitForAvailableFrame(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.wg_process.wait();
    self.wg_process.reset();
    try self.impl.waitForFreeFrame();
}

pub fn pushProcessParallel(self: *@This(), ctx: *lifetime.ContextBase) anyerror!void {
    ctx.thread_pool.spawnWg(&self.wg_process, process, .{ self, ctx });
}

pub fn process(self: *@This(), _: *lifetime.ContextBase) void {
    self.impl.process() catch |e| utils.tried.panic(e, @errorReturnTrace());
}

pub fn setCameraPosition(self: *@This(), pos: @Vector(2, i32)) void {
    self.impl.camera_pos = pos;
}

pub fn pushCmdLine(self: *@This(), data: types.LineData) !void {
    try self.impl.scheduleLine(data.points, data.color, data.depth, data.alpha_gradient);
}

pub fn pushCmdVertices(self: *@This(), vertices: []const types.VertexData) !void {
    try self.impl.scheduleVertices(vertices);
}

pub fn pushCmdTriangle(self: *@This(), vertex: [3]types.VertexData) !void {
    for (vertex) |v| try self.impl.scheduleVertex(v);
}

pub fn pushGuiCmdChar(self: *@This(), data: types.TextData) !void {
    try self.impl.scheduleGuiChar(data);
}

pub fn pushGuiTriangle(self: *@This(), data: []const types.VertexData) !void {
    try self.impl.scheduleGuiTriangle(data);
}

pub fn pushGuiLine(self: *@This(), data: []const types.VertexData) !void {
    try self.impl.scheduleGuiLine(data);
}

pub fn pushGuiScissor(self: *@This(), offset: @Vector(2, i32), extent: @Vector(2, u32)) !void {
    try self.impl.scheduleGuiScissor(.{ .offset = offset, .extent = extent });
}

pub fn prepareLandscapeUpdateRegion(self: *@This()) ![]const Backend.Landscape.ActiveSet {
    try self.impl.currentFrameData().landscape.recalculateActiveSets(@intCast(self.impl.camera_pos));
    self.impl.currentFrameData().landscape_upload.resize(0) catch unreachable;
    return self.impl.currentFrameData().landscape.active_sets.constSlice();
}

pub fn getLandscapeVisibleExtent(self: *@This()) vk.Rect2D {
    return vk.Rect2D{
        .extent = .{
            .width = Backend.frame_target_width,
            .height = Backend.frame_target_height,
        },
        .offset = .{
            .x = self.impl.camera_pos[0] - Backend.frame_target_width / 2,
            .y = self.impl.camera_pos[1] - Backend.frame_target_height / 2,
        },
    };
}

pub fn pushCmdLandscapeTileUpdate(self: *@This(), dst: *Backend.Landscape.Tile, data: []const u8) !void {
    try self.impl.currentFrameData().landscape_upload.append(.{ .tile = dst, .data = data });
}

/// TODO If called, ensures landscape is drawn this frame.
pub fn shouldDrawLandscape(_: *@This()) void {
    // Always drawn anyway for now
}
