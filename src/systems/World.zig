const std = @import("std");

const SandSim = @import("World/SandSim.zig");

const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");

allocator: std.mem.Allocator,
sand_sim: SandSim,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .sand_sim = undefined,
    };
}

pub fn systemInit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.sand_sim = try SandSim.init(self.allocator);
}

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.sand_sim.deinit();
    self.sand_sim = undefined;
}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn tickProcessSandSimCells(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    try self.sand_sim.simulateCells();
}

pub fn tickProcessSandSimParticles(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try self.sand_sim.simulateParticles(ctx.systems.time.tickDelay());
}

pub fn render(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    const set = try ctx.systems.vulkan.prepareLandscapeUpdateRegion();
    const lve = ctx.systems.vulkan.getLandscapeVisibleExtent();

    const ss_node_extent = SandSim.NodeExtent{
        .coord = .{ lve.offset.x, lve.offset.y },
        .size = .{ lve.extent.width, lve.extent.height },
    };

    try self.sand_sim.ensureArea(ss_node_extent);
    var tiles: [12]*SandSim.Tile = undefined;
    const used_tiles = try self.sand_sim.fillTilesFromArea(ss_node_extent, &tiles);

    for (used_tiles) |src| for (set) |dst| {
        if (@reduce(.Or, src.coord != dst.tile.coord)) continue;
        try ctx.systems.vulkan.pushCmdLandscapeTileUpdate(dst.tile, std.mem.asBytes(&src.matrix));
    };

    ctx.systems.vulkan.shouldDrawLandscape();

    for (self.sand_sim.particles.items) |particle| {
        const point_a = particle.pos - particle.vel * @as(@Vector(2, f32), @splat(ctx.systems.time.tickDelay()));
        const point_b = particle.pos;

        try ctx.systems.vulkan.pushCmdLine(.{
            .points = .{ point_a, point_b },
            .color = .{ 0.0, 0.0, 1.0, 1.0 },
            .depth = 0.01,
            .alpha_gradient = .{ 1.0, 1.0 },
        });
    }
}
