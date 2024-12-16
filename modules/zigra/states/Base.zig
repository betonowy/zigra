const std = @import("std");
const util = @import("util");
const root = @import("../root.zig");
const modules = @import("../systems.zig");
const build_options = @import("options");

usingnamespace @import("common.zig");

const log = std.log.scoped(.states_Base);

pub const InitOptions = struct {
    allocator: std.mem.Allocator,
    resource_dir: []const u8,
};

allocator: std.mem.Allocator,
resource_dir: []const u8,

pub fn init(options: InitOptions) !*@This() {
    const self = try options.allocator.create(@This());
    errdefer options.allocator.destroy(self);

    const resource_dir = try options.allocator.dupe(u8, options.resource_dir);

    self.* = .{ .allocator = options.allocator, .resource_dir = resource_dir };
    return self;
}

pub fn enter(self: @This(), _: *root.Sequencer, m: *root.Modules) !void {
    util.meta.logFn(log, @src());

    m.thread_pool = try modules.ThreadPool.init(self.allocator);
    errdefer m.thread_pool.deinit();

    m.audio = try modules.Audio.init(self.allocator);
    errdefer m.audio.deinit();

    var zaudio_result: anyerror!void = {};
    var zaudio_launch_event = std.Thread.ResetEvent{};
    var zaudio_result_event = std.Thread.ResetEvent{};

    const closure = struct {
        pub fn call(
            audio: *modules.Audio,
            result: *anyerror!void,
            launch_event: *std.Thread.ResetEvent,
            result_event: *std.Thread.ResetEvent,
        ) void {
            launch_event.wait();
            result.* = audio.zaudioInit();
            result_event.set();
        }
    };

    var zaudio_thd = try std.Thread.spawn(.{}, closure.call, .{
        &m.audio,
        &zaudio_result,
        &zaudio_launch_event,
        &zaudio_result_event,
    });
    defer zaudio_thd.join();

    zaudio_thd.setName("zaudio") catch log.err("Failed to set zaudio thread name", .{});
    zaudio_launch_event.set();

    //
    // Here is place for future async resource dir lookup, resource loading
    //

    m.window = try modules.Window.init(self.allocator);
    errdefer m.window.deinit();
    m.window.setup();

    m.vulkan = try modules.Vulkan.init(self.allocator, m);
    errdefer m.vulkan.deinit();

    m.nuklear = try modules.Nuklear.init(self.allocator);
    errdefer m.nuklear.deinit();
    try m.nuklear.systemInit(m);

    m.time = try modules.Time.init(self.allocator);
    errdefer m.time.deinit();

    m.entities = try modules.Entities.init(self.allocator);
    errdefer m.entities.deinit();

    m.net = try modules.Net.init(self.allocator);
    errdefer m.net.deinit();
    try m.net.systemInit(m);

    m.sprite_man = try modules.SpriteMan.init(self.allocator);
    errdefer m.sprite_man.deinit();

    m.world = try modules.World.init(self.allocator);
    errdefer m.world.deinit();
    try m.world.systemInit(m);

    m.transform = try modules.Transform.init(self.allocator);
    errdefer m.transform.deinit();

    m.bodies = try modules.Bodies.init(self.allocator);
    errdefer m.bodies.deinit();

    if (build_options.debug_ui) m.debug_ui = try modules.DebugUI.init(self.allocator);
    errdefer if (build_options.debug_ui) m.debug_ui.deinit();

    m.camera = try modules.Camera.init(m);
    errdefer m.camera = undefined;

    m.background = try modules.Background.init(self.allocator);
    errdefer m.background.deinit();

    // sync audio init
    zaudio_result_event.wait();
    try zaudio_result;
}

pub fn updateEnter(_: @This(), _: *root.Sequencer, m: *root.Modules) !void {
    try m.window.process(m);
    try m.nuklear.inputProcess(m);
    if (build_options.debug_ui) try m.debug_ui.processUi(m);
    try m.nuklear.postProcess(m);
}

pub fn tickEnter(_: @This(), _: *root.Sequencer, m: *root.Modules) !void {
    try m.net.tickBegin(m);
}

pub fn tickExit(_: @This(), _: *root.Sequencer, m: *root.Modules) !void {
    try m.world.tickProcessSandSimCells(m);
    try m.world.tickProcessSandSimParticles(m);
    try m.bodies.tickProcessBodies(m);
    try m.camera.tick(m);
    try m.net.tickEnd(m);
    m.time.finishTick(m);
}

pub fn updateExit(_: @This(), _: *root.Sequencer, m: *root.Modules) !void {
    try m.camera.update(m);
    try m.vulkan.waitForAvailableFrame(m);
    try m.background.render(m);
    try m.world.render(m);
    try m.nuklear.render(m);
    try m.sprite_man.render(m);
    try m.vulkan.pushProcessParallel(m);
    try m.entities.executePendingDestructions(m);
    if (build_options.profiling and build_options.debug_ui) try m.debug_ui.processProfilingData(m);
    m.time.checkpoint(m);
}

pub fn exit(self: *@This(), _: *root.Sequencer, m: *root.Modules) void {
    util.meta.logFn(log, @src());

    m.background.deinit();
    m.camera = undefined;
    m.nuklear.deinit();
    m.bodies.deinit();
    m.transform.deinit();
    m.world.deinit();
    m.sprite_man.deinit();
    m.net.deinit();
    m.vulkan.deinit();
    if (build_options.debug_ui) m.debug_ui.deinit();
    m.window.deinit();
    m.audio.deinit();
    m.entities.deinit();
    m.time.deinit();
    m.thread_pool.deinit();
    self.allocator.free(self.resource_dir);
    self.allocator.destroy(self);
}
