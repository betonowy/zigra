const std = @import("std");

pub const SandSim = @import("World/SandSim.zig");
const world_net = @import("World/net.zig");

const lifetime = @import("lifetime");
const root = @import("../root.zig");
const Net = @import("Net.zig");
const lz4 = @import("lz4");
const la = @import("la");
const common = @import("common.zig");

const log = std.log.scoped(.World);

allocator: std.mem.Allocator,
sand_sim: SandSim,

render_sync: ?std.Thread.ResetEvent = null,

id_channel: u8 = undefined,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .sand_sim = undefined,
    };
}

pub fn systemInit(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    self.sand_sim = try SandSim.init(self.allocator);
    self.id_channel = try m.net.registerChannel(Net.Channel.init(self));
}

pub fn deinit(self: *@This()) void {
    self.sand_sim.deinit();
    self.sand_sim = undefined;
    self.* = undefined;
}

pub fn tickCells(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    try self.sand_sim.simulateCells();
}

pub fn tickParticles(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    try self.sand_sim.simulateParticles(m.time.tickDelay());
}

pub fn render(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    const landscape = &m.vulkan.impl.currentFrameDataPtr().images.landscape_encoded_host;

    const mem = landscape.map orelse try landscape.mapMemory();
    const size = landscape.options.extent;

    try self.sand_sim.fillView(.{
        .coord = m.vulkan.impl.camera_pos -
            @Vector(2, i32){ @intCast(size[0]), @intCast(size[1]) } /
            la.splatT(2, i32, 2),
        .size = .{ size[0], size[1] },
    }, m.time.tickDelay(), mem);

    // for (self.sand_sim.particles.items) |particle| {
    //     const point_a = particle.pos - particle.vel * @as(@Vector(2, f32), @splat(m.time.tickDelay()));
    //     const point_b = particle.pos;

    //     try m.vulkan.pushCmdLine(.{
    //         .points = .{ point_a, point_b },
    //         .color = .{ 0.0125, 0.025, 0.5, 1.0 },
    //         .depth = 0.01,
    //         .alpha_gradient = .{ 1.0, 1.0 },
    //     });
    // }
}

pub fn netRecv(self: *@This(), m: *root.Modules, data: []const u8) !void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();

    switch (try reader.readEnum(world_net.PacketType, .little)) {
        .sync_all => try self.netRecvSyncTiles(&stream, reader, data),
    }
}

fn netRecvSyncTiles(
    self: *@This(),
    stream: *std.io.FixedBufferStream([]const u8),
    reader: std.io.FixedBufferStream([]const u8).Reader,
    data: []const u8,
) !void {
    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    const header = try reader.readStructEndian(world_net.SyncTilesHeader, .little);

    const stream_pos = try stream.getPos();
    const tile_begin = stream_pos;
    const tile_end_particle_begin = tile_begin + header.tile_entry_stream_size_compressed;
    const particle_end = tile_end_particle_begin + header.particle_entry_stream_size_compressed;

    const tile_lz4_slice = data[tile_begin..tile_end_particle_begin];
    const particle_lz4_slice = data[tile_end_particle_begin..particle_end];

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    if (header.tile_entry_count > 0) {
        const tiles = try arena.allocator().alloc(world_net.TileEntry, header.tile_entry_count);
        try lz4.decompress(tile_lz4_slice, std.mem.sliceAsBytes(tiles));

        try self.sand_sim.ensureArea(.{
            .coord = header.bound_min,
            .size = @intCast(header.bound_max - header.bound_min),
        });

        var view = self.sand_sim.getView();
        for (tiles[0..]) |*entry| (try view.getTile(entry.tile.coord) orelse unreachable).* = entry.tile;
    }

    _ = arena.reset(.retain_capacity);

    if (header.particle_entry_count > 0) {
        const particles = try arena.allocator().alloc(world_net.ParticleEntry, header.particle_entry_count);
        try lz4.decompress(particle_lz4_slice, std.mem.sliceAsBytes(particles));

        self.sand_sim.particles.clearRetainingCapacity();
        try self.sand_sim.particles.ensureTotalCapacity(self.sand_sim.allocator, particles.len);

        for (particles[0..]) |*entry| self.sand_sim.particles.appendAssumeCapacity(entry.particle);
    }

    self.sand_sim.iteration = header.iteration;
}

pub fn netSyncAll(self: *@This(), m: *root.Modules) !void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    log.info("netSyncAll", .{});

    const tile_count: u32 = self.sand_sim.countTiles();
    const particle_count: u32 = @intCast(self.sand_sim.particles.items.len);
    log.info("Tile count: {}, particle count: {}", .{ tile_count, particle_count });

    const max_packet_len =
        @sizeOf(world_net.PacketType) +
        @sizeOf(world_net.SyncTilesHeader) +
        lz4.compressBound(particle_count * @sizeOf(world_net.ParticleEntry)) +
        lz4.compressBound(tile_count * @sizeOf(world_net.TileEntry));

    log.info("Max expected buffer: {}", .{max_packet_len});
    log.info("Pushing {} tiles", .{tile_count});
    log.info("Pushing {} particles", .{particle_count});

    const packet_buffer = try self.allocator.alloc(u8, max_packet_len);
    defer self.allocator.free(packet_buffer);

    var tile_array = try std.ArrayList(world_net.TileEntry).initCapacity(self.allocator, tile_count);
    defer tile_array.deinit();

    var for_each_ctx: struct {
        tiles: *std.ArrayList(world_net.TileEntry),
        bound_min: @Vector(2, i32) = .{ 0, 0 },
        bound_max: @Vector(2, i32) = .{ 0, 0 },

        pub fn func(ctx: *@This(), tile: *SandSim.Tile) void {
            ctx.bound_min = @min(ctx.bound_min, tile.getBound(.Min));
            ctx.bound_max = @max(ctx.bound_max, tile.getBound(.Max));
            ctx.tiles.appendAssumeCapacity(.{ .tile = tile.* });
        }
    } = .{ .tiles = &tile_array };

    self.sand_sim.forEachNode(&for_each_ctx);

    var particle_array = try std.ArrayList(world_net.ParticleEntry).initCapacity(self.allocator, particle_count);
    defer particle_array.deinit();

    for (self.sand_sim.particles.items) |p| particle_array.appendAssumeCapacity(.{ .particle = p });

    var lz4_tiles = try lz4.compress(self.allocator, std.mem.sliceAsBytes(tile_array.items), .lc);
    defer lz4_tiles.deinit(self.allocator);

    var lz4_particles = try lz4.compress(self.allocator, std.mem.sliceAsBytes(particle_array.items), .lc);
    defer lz4_particles.deinit(self.allocator);

    var output_stream = std.io.fixedBufferStream(packet_buffer);
    const output_writer = output_stream.writer();

    try output_writer.writeAll(std.mem.asBytes(&world_net.PacketType.sync_all));

    try output_writer.writeStructEndian(world_net.SyncTilesHeader{
        .iteration = self.sand_sim.iteration,
        .bound_min = for_each_ctx.bound_min,
        .bound_max = for_each_ctx.bound_max,
        .tile_entry_count = tile_count,
        .particle_entry_count = particle_count,
        .tile_entry_stream_size_compressed = @intCast(lz4_tiles.items.len),
        .particle_entry_stream_size_compressed = @intCast(lz4_particles.items.len),
        .tile_entry_stream_size_decompressed = @intCast(tile_array.items.len * @sizeOf(world_net.TileEntry)),
        .particle_entry_stream_size_decompressed = @intCast(particle_array.items.len * @sizeOf(world_net.ParticleEntry)),
    }, .little);

    try output_writer.writeAll(lz4_tiles.items);
    try output_writer.writeAll(lz4_particles.items);

    log.info("Resulting buffer: {}", .{output_stream.getWritten().len});

    try m.net.send(self.id_channel, output_stream.getWritten(), .{ .reliable = true });
}
