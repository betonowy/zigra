const std = @import("std");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

const options = @import("options");

pub const StateGame = union(enum) {
    GameNormal: void,
};

pub const StateTimer = union(enum) {
    Normal: void,
    Limited: void,
};

state_game: StateGame = .GameNormal,
state_timer: StateTimer = .Limited,

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
        .GameNormal => try self.runLoop_GameNormal(ctx),
    }

    if (options.profiling) {
        try run(ctx, .debug_ui, .processProfilingData);
    }
}

fn runLoop_GameNormal(self: *@This(), ctx: *zigra.Context) !void {
    {
        var timer = try std.time.Timer.start();

        try runLoopPreTicks(self, ctx);

        try ctx.systems.debug_ui.pushOtherProfilingData(.{
            .call_name = "Pre ticks",
            .duration_ns = timer.read(),
            .timestamp = 1,
        });
    }
    {
        var timer = try std.time.Timer.start();

        for (0..ctx.systems.time.ticks_this_checkpoint) |_| try runLoopTick(self, ctx);

        try ctx.systems.debug_ui.pushOtherProfilingData(.{
            .call_name = "Tick loop",
            .duration_ns = timer.read(),
            .timestamp = 2,
        });
    }
    {
        var timer = try std.time.Timer.start();

        try runLoopPostTicks(self, ctx);

        try ctx.systems.debug_ui.pushOtherProfilingData(.{
            .call_name = "Post ticks",
            .duration_ns = timer.read(),
            .timestamp = 3,
        });
    }
    {
        switch (self.state_timer) {
            .Limited => {
                var timer = try std.time.Timer.start();

                try run(ctx, .time, .ensureMinimumCheckpointTime);

                try ctx.systems.debug_ui.pushOtherProfilingData(.{
                    .call_name = "Checkpoint wait",
                    .duration_ns = timer.read(),
                    .timestamp = 4,
                });
            },
            else => {},
        }
    }
}

fn runLoopPreTicks(_: *@This(), ctx: *zigra.Context) !void {
    try run(ctx, .time, .checkpoint);
    try run(ctx, .window, .process);
    try run(ctx, .imgui, .inputProcess);
    try run(ctx, .imgui, .process);
    try run(ctx, .debug_ui, .processUi);
}

fn runLoopTick(_: *@This(), ctx: *zigra.Context) !void {
    try run(ctx, .world, .tickProcessSandSimCells);
    try run(ctx, .world, .tickProcessSandSimParticles);
    try run(ctx, .playground, .tickProcess);
    try run(ctx, .bodies, .tickProcessPointBodies);
    try run(ctx, .time, .finishTick);
}

fn runLoopPostTicks(_: *@This(), ctx: *zigra.Context) !void {
    try run(ctx, .transform, .calculateVisualPositions);
    try run(ctx, .vulkan, .waitForPreviousWorkToFinish);
    try run(ctx, .world, .render);
    try run(ctx, .imgui, .render);
    try run(ctx, .sprite_man, .render);
    try run(ctx, .vulkan, .process);
}

fn run(ctx: *zigra.Context, comptime system_tag: anytype, comptime function_tag: anytype) !void {
    const system_ptr = &@field(ctx.systems, @tagName(system_tag));

    if (options.profiling) {
        var timer = try std.time.Timer.start();
        try @field(@TypeOf(system_ptr.*), @tagName(function_tag))(system_ptr, &ctx.base);
        const ns = timer.read();

        const result = try ctx.systems.debug_ui.profiling_system_ctx_map.getOrPut(
            @tagName(system_tag) ++ "." ++ @tagName(function_tag) ++ "()",
        );

        if (!result.found_existing) result.value_ptr.* = .{};

        result.value_ptr.push(ns, ctx.systems.time.timer_main.read());
    } else {
        try @field(@TypeOf(system_ptr.*), @tagName(function_tag))(system_ptr, &ctx.base);
    }
}
