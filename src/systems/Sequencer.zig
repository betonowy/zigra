const std = @import("std");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

const options = @import("options");

pub const StateGame = union(enum) {
    GameNormal: void,
};

pub const StateTimer = union(enum) {
    Normal: void,
};

pub const StateDebugGui = union(enum) {
    Disabled: void,
    Basic: void,
};

state_game: StateGame = .GameNormal,
state_timer: StateTimer = .Normal,
state_debug_gui: StateDebugGui = .Basic,

pub fn runInit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    try ctx.systems.window.systemInit(ctx_base);
    try ctx.systems.vulkan.systemInit(ctx_base);
    try ctx.systems.imgui.systemInit(ctx_base);
    try ctx.systems.world.systemInit(ctx_base);
    try ctx.systems.playground.systemInit(ctx_base);
}

pub fn runDeinit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    try ctx.systems.playground.systemDeinit(ctx_base);
    try ctx.systems.world.systemDeinit(ctx_base);
    try ctx.systems.imgui.systemDeinit(ctx_base);
    try ctx.systems.vulkan.systemDeinit(ctx_base);
    try ctx.systems.window.systemDeinit(ctx_base);
}

pub fn runLoop(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    switch (self.state_game) {
        .GameNormal => try self.runLoop_GameNormal(ctx_base, ctx),
    }

    if (options.profiling) {
        try ctx.systems.debug_ui.processProfilingData(ctx_base);
    }
}

fn runLoop_GameNormal(self: *@This(), ctx_base: *lifetime.ContextBase, ctx: *zigra.Context) !void {
    {
        var timer = try std.time.Timer.start();

        try runLoopPreTicks(self, ctx_base, ctx);

        try ctx.systems.debug_ui.pushCallProfilingData(.{
            .call_name = "Pre ticks",
            .duration_ns = timer.read(),
            .start_ns = 1,
        });
    }
    {
        var timer = try std.time.Timer.start();

        for (0..ctx.systems.time.ticks_this_checkpoint) |_| try runLoopTick(self, ctx_base, ctx);

        try ctx.systems.debug_ui.pushCallProfilingData(.{
            .call_name = "Tick loop",
            .duration_ns = timer.read(),
            .start_ns = 1,
        });
    }
    {
        var timer = try std.time.Timer.start();

        try runLoopPostTicks(self, ctx_base, ctx);

        try ctx.systems.debug_ui.pushCallProfilingData(.{
            .call_name = "Pre ticks",
            .duration_ns = timer.read(),
            .start_ns = 1,
        });
    }
}

fn runLoopPreTicks(_: *@This(), ctx_base: *lifetime.ContextBase, ctx: *zigra.Context) !void {
    try ctx.systems.time.checkpoint(ctx_base);
    try ctx.systems.window.process(ctx_base);
    try ctx.systems.imgui.inputProcess(ctx_base);
    try ctx.systems.imgui.process(ctx_base);
    try ctx.systems.debug_ui.processUi(ctx_base);
}

fn runLoopTick(_: *@This(), ctx_base: *lifetime.ContextBase, ctx: *zigra.Context) !void {
    try ctx.systems.world.tickProcessSandSimCells(ctx_base);
    try ctx.systems.world.tickProcessSandSimParticles(ctx_base);
    try ctx.systems.playground.tickProcess(ctx_base);
}

fn runLoopPostTicks(_: *@This(), ctx_base: *lifetime.ContextBase, ctx: *zigra.Context) !void {
    try ctx.systems.vulkan.waitForPreviousWorkToFinish(ctx_base);
    try ctx.systems.world.render(ctx_base);
    try ctx.systems.imgui.render(ctx_base);
    try ctx.systems.vulkan.process(ctx_base);
    try ctx.systems.time.ensureMinimumCheckpointTime(ctx_base);
}
