const std = @import("std");

const Backend = @import("Vulkan/Backend.zig");

const lifetime = @import("lifetime");
const tracy = @import("tracy");
const utils = @import("util");
const root = @import("../root.zig");
const common = @import("common.zig");

pub const shader_io = @import("Vulkan/shader_io.zig");
pub const Atlas = @import("Vulkan/Atlas.zig");
pub const vk = @import("vk");

allocator: std.mem.Allocator,
impl: Backend,

wg_process: std.Thread.WaitGroup,

pub fn init(allocator: std.mem.Allocator, m: *root.Modules) !@This() {
    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    var self = @This(){
        .allocator = allocator,
        .impl = undefined,
        .wg_process = std.Thread.WaitGroup{},
    };

    self.impl = try Backend.init(
        self.allocator,
        @as(vk.PfnGetInstanceProcAddr, @ptrCast(m.window.pfnGetInstanceProcAddress())),
        &m.window.cbs_vulkan,
    );

    return self;
}

pub fn deinit(self: *@This()) void {
    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    self.wg_process.wait();
    self.wg_process.reset();
    self.impl.deinit();
    self.* = undefined;
}

pub fn waitForFrame(self: *@This(), _: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    self.wg_process.wait();
    self.wg_process.reset();
    try self.impl.waitForFreeFrame();
}

pub fn schedule(self: *@This(), m: *root.Modules) anyerror!void {
    self.impl.updateHostData();

    common.systemMessage(@This(), @src());
    m.thread_pool.spawnWg(&self.wg_process, process, .{ self, m });
}

pub fn process(self: *@This(), m: *root.Modules) void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    self.impl.process() catch |e| utils.tried.panic(e, @errorReturnTrace());
}

pub fn setCameraPosition(self: *@This(), pos: @Vector(2, i32)) void {
    self.impl.camera_pos_diff = pos - self.impl.camera_pos;
    self.impl.camera_pos = pos;
}

pub const BkgEntry = shader_io.Ubo.Background.Entry;

pub fn pushBkgEntry(self: *@This(), entry: BkgEntry) !void {
    try self.impl.upload_bkg_layers.append(entry);
}

pub const WorldVertex = shader_io.Vertex;

pub fn pushWorldVertices(self: *@This(), vertices: []const WorldVertex) !void {
    try self.impl.currentFrameDataPtr().dbs.world.pushVertices(vertices);
}

pub const GuiVertex = shader_io.Vertex;

pub fn pushGuiVertices(self: *@This(), data: []const GuiVertex) !void {
    try self.impl.currentFrameDataPtr().dbs.dui.pushVertices(data);
}

pub const GuiScissor = @import("Vulkan/DebugUiData.zig").GuiBlock.Scissor;

pub fn pushGuiScissor(self: *@This(), offset: @Vector(2, i32), extent: @Vector(2, u32)) !void {
    try self.impl.currentFrameDataPtr().dbs.dui.pushScissor(.{ .offset = offset, .extent = extent });
}
