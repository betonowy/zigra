const std = @import("std");
const lifetime = @import("lifetime");
const tracy = @import("tracy");
const options = @import("options");

const zigra = @import("../root.zig");

pub const State = union(enum) {
    GameNormal: void,
    Black: void,
    CloudTransition: void,
};

pub const StateTimer = union(enum) {
    Normal: void,
    Limited: void,
};

state: State = .GameNormal,
state_next: State = .GameNormal,
state_timer: StateTimer = .Limited,

pub fn runInit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const t = tracy.trace(@src());
    defer t.end();

    const ctx = ctx_base.parent(zigra.Context);

    try runLean(ctx, .net, .systemInit);
    try runLean(ctx, .window, .systemInit);
    try runLean(ctx, .world, .systemInit);
    try runLean(ctx, .vulkan, .systemInit);
    try runLean(ctx, .nuklear, .systemInit);
    try runLean(ctx, .playground, .systemInit);
}

pub fn runDeinit(_: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const t = tracy.trace(@src());
    defer t.end();

    const ctx = ctx_base.parent(zigra.Context);

    try runLean(ctx, .playground, .systemDeinit);
    try runLean(ctx, .nuklear, .systemDeinit);
    try runLean(ctx, .vulkan, .systemDeinit);
    try runLean(ctx, .world, .systemDeinit);
    try runLean(ctx, .window, .systemDeinit);
    try runLean(ctx, .net, .systemDeinit);
}

pub fn runLoop(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    tracy.frameMark();
    const t = tracy.trace(@src());
    defer t.end();

    const ctx = ctx_base.parent(zigra.Context);

    try runLoopPreTicks(self, ctx);
    for (0..ctx.systems.time.ticks_this_checkpoint) |_| try runLoopTick(self, ctx);
    try runLoopPostTicks(self, ctx);
    try run(ctx, .time, .ensureMinimumCheckpointTime);

    if (options.profiling and options.debug_ui) {
        try run(ctx, .debug_ui, .processProfilingData);
    }
}

fn runLoopPreTicks(_: *@This(), ctx: *zigra.Context) !void {
    const t = tracy.trace(@src());
    defer t.end();

    try run(ctx, .time, .checkpoint);
    try run(ctx, .window, .process);
    try run(ctx, .nuklear, .inputProcess);
    if (options.debug_ui) try run(ctx, .debug_ui, .processUi);
    try run(ctx, .nuklear, .postProcess);
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
    return runEx(ctx, system_tag, function_tag, .profiling);
}

fn runLean(ctx: *zigra.Context, comptime system_tag: anytype, comptime function_tag: anytype) !void {
    return runEx(ctx, system_tag, function_tag, .lean);
}

fn runEx(
    ctx: *zigra.Context,
    comptime system_tag: anytype,
    comptime function_tag: anytype,
    comptime flavor: enum { lean, profiling },
) !void {
    const system_ptr = &@field(ctx.systems, @tagName(system_tag));
    const routine_name = @tagName(system_tag) ++ "." ++ @tagName(function_tag);

    if (options.profiling and options.debug_ui and flavor == .profiling) {
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
