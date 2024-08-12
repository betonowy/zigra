const Self = @import("../Net.zig");

pub const PacketType = enum(u8) {
    connection_data,
    sync_all,
};

pub const ConnectionData = extern struct {
    id_peer: u32,
};
