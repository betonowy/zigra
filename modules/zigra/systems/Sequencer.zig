const std = @import("std");
const lifetime = @import("lifetime");
const tracy = @import("tracy");
const options = @import("options");

const zigra = @import("../root.zig");

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
    const t = tracy.trace(@src());
    defer t.end();

    const ctx = ctx_base.parent(zigra.Context);

    try ctx.systems.net.systemInit(ctx_base);
    try ctx.systems.window.systemInit(ctx_base);
    try ctx.systems.vulkan.systemInit(ctx_base);
    try ctx.systems.nuklear.systemInit(ctx_base);
    try ctx.systems.world.systemInit(ctx_base);
    try ctx.systems.playground.systemInit(ctx_base);
}

pub fn runDeinit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const t = tracy.trace(@src());
    defer t.end();

    const ctx = ctx_base.parent(zigra.Context);

    try ctx.systems.playground.systemDeinit(ctx_base);
    try ctx.systems.world.systemDeinit(ctx_base);
    try ctx.systems.nuklear.systemDeinit(ctx_base);
    try ctx.systems.vulkan.systemDeinit(ctx_base);
    try ctx.systems.window.systemDeinit(ctx_base);
    try ctx.systems.net.systemDeinit(ctx_base);
}

pub fn runLoop(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    tracy.frameMark();
    const t = tracy.trace(@src());
    defer t.end();

    ctx_base.worker_group.current_index = 0;

    const ctx = ctx_base.parent(zigra.Context);

    switch (self.state_game) {
        .GameNormal => try self.runLoop_GameNormal(ctx),
    }

    if (options.profiling and options.debug_ui) {
        try run(ctx, .debug_ui, .processProfilingData);
    }
}

fn runLoop_GameNormal(self: *@This(), ctx: *zigra.Context) !void {
    const t = tracy.trace(@src());
    defer t.end();

    {
        var timer = try std.time.Timer.start();

        try runLoopPreTicks(self, ctx);

        if (options.debug_ui) try ctx.systems.debug_ui.pushOtherProfilingData(.{
            .call_name = "Pre ticks",
            .duration_ns = timer.read(),
            .timestamp = 1,
        });
    }
    {
        var timer = try std.time.Timer.start();

        for (0..ctx.systems.time.ticks_this_checkpoint) |_| try runLoopTick(self, ctx);

        if (options.debug_ui) try ctx.systems.debug_ui.pushOtherProfilingData(.{
            .call_name = "Tick loop",
            .duration_ns = timer.read(),
            .timestamp = 2,
        });
    }
    {
        var timer = try std.time.Timer.start();

        try runLoopPostTicks(self, ctx);

        if (options.debug_ui) try ctx.systems.debug_ui.pushOtherProfilingData(.{
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

                if (options.debug_ui) try ctx.systems.debug_ui.pushOtherProfilingData(.{
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
    const t = tracy.trace(@src());
    defer t.end();

    try run(ctx, .time, .checkpoint);
    try run(ctx, .window, .process);
    try run(ctx, .nuklear, .inputProcess);
    try run(ctx, .nuklear, .process);
    if (options.debug_ui) try run(ctx, .debug_ui, .processUi);
}

fn runLoopTick(_: *@This(), ctx: *zigra.Context) !void {
    const t = tracy.trace(@src());
    defer t.end();

    try run(ctx, .net, .tickBegin);
    try run(ctx, .world, .tickProcessSandSimCells);
    try run(ctx, .world, .tickProcessSandSimParticles);
    try run(ctx, .playground, .tickProcess);
    try run(ctx, .bodies, .tickProcessBodies);
    try run(ctx, .time, .finishTick);
    try run(ctx, .net, .tickEnd);
}

fn runLoopPostTicks(_: *@This(), ctx: *zigra.Context) !void {
    const t = tracy.trace(@src());
    defer t.end();

    try run(ctx, .vulkan, .waitForAvailableFrame);
    try run(ctx, .world, .render);
    try run(ctx, .nuklear, .render);
    try run(ctx, .sprite_man, .render);
    try run(ctx, .vulkan, .pushProcessParallel);
}

fn run(ctx: *zigra.Context, comptime system_tag: anytype, comptime function_tag: anytype) !void {
    const system_ptr = &@field(ctx.systems, @tagName(system_tag));
    const routine_name = @tagName(system_tag) ++ "." ++ @tagName(function_tag);

    if (options.profiling and options.debug_ui) {
        var timer = try std.time.Timer.start();
        {
            const t = tracy.traceNamed(@src(), routine_name);
            defer t.end();
            try @field(@TypeOf(system_ptr.*), @tagName(function_tag))(system_ptr, &ctx.base);
        }
        const ns = timer.read();

        const result = try ctx.systems.debug_ui.profiling_system_ctx_map.getOrPut(routine_name);

        if (!result.found_existing) result.value_ptr.* = .{};

        result.value_ptr.push(ns, ctx.systems.time.timer_main.read());
    } else {
        const t = tracy.traceNamed(@src(), routine_name);
        defer t.end();
        try @field(@TypeOf(system_ptr.*), @tagName(function_tag))(system_ptr, &ctx.base);
    }
}
