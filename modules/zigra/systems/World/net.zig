const SandSim = @import("SandSim.zig");

pub const PacketType = enum(u8) {
    sync_all,
};

pub const SyncTilesHeader = extern struct {
    iteration: u64,
    bound_min: @Vector(2, i32),
    bound_max: @Vector(2, i32),
    tile_entry_count: u32,
    tile_entry_stream_size_compressed: u32,
    tile_entry_stream_size_decompressed: u32,
    particle_entry_count: u32,
    particle_entry_stream_size_compressed: u32,
    particle_entry_stream_size_decompressed: u32,
};

pub const TileEntry = extern struct {
    tile: SandSim.Tile,
};

pub const ParticleEntry = extern struct {
    particle: SandSim.CellParticle,
};
