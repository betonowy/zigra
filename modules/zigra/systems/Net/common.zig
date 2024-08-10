const Self = @import("../Net.zig");

pub const PacketType = enum(u8) {
    connection_data,
};

pub const ConnectionData = extern struct {
    id_peer: u32,
};
