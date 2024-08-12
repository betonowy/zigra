const std = @import("std");
const enet = @import("enet");

const Self = @import("../Net.zig");
const zigra = @import("../../root.zig");
const common = @import("common.zig");

const log = std.log.scoped(.NetMaster);

pub fn tickBegin(self: *Self, ctx: *zigra.Context, enet_ctx: *enet.HostServer) !void {
    const handler: struct {
        parent: *Self,
        ctx: *zigra.Context,

        pub fn connect(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostServer) !void {
            try onConnect(handler.parent, handler.ctx, host, id_peer, peer);
        }

        pub fn disconnect(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostServer) !void {
            try onDisconnect(handler.parent, handler.ctx, host, id_peer, peer);
        }

        pub fn disconnectTimeout(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostServer) !void {
            try onDisconnect(handler.parent, handler.ctx, host, id_peer, peer);
        }

        pub fn receive(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostServer, data: []const u8, channel: u32) !void {
            try onReceive(handler.parent, handler.ctx, host, id_peer, peer, data, channel);
        }
    } = .{ .parent = self, .ctx = ctx };

    try enet_ctx.service(handler);
}

pub fn tickEnd(_: *Self, _: *zigra.Context, enet_ctx: *enet.HostServer) !void {
    enet_ctx.flush();
}

pub fn send(enet_ctx: *enet.HostServer, id_channel: u8, data: []const u8, options: enet.PacketOptions) !void {
    try enet_ctx.broadcastPacket(data, id_channel, options);
}

fn onConnect(self: *Self, _: *zigra.Context, enet_ctx: *enet.HostServer, id_peer: u32, peer: *enet.Peer) !void {
    var buf = std.BoundedArray(u8, 8){};
    const writer = buf.writer();

    log.info("Slave connected: {}", .{id_peer});

    try writer.writeByte(@intFromEnum(common.PacketType.connection_data));
    try writer.writeStructEndian(common.ConnectionData{ .id_peer = id_peer }, .little);

    try enet_ctx.sendPacket(peer, buf.constSlice(), @intCast(self.id_channel));
}

fn onDisconnect(_: *Self, _: *zigra.Context, _: *enet.HostServer, id_peer: u32, _: *enet.Peer) !void {
    log.info("Slave disconnected: {}", .{id_peer});
}

fn onReceive(self: *Self, ctx: *zigra.Context, _: *enet.HostServer, _: u32, _: *enet.Peer, data: []const u8, channel: u32) !void {
    const handler = self.system_channels.at(channel);
    try handler.recv(&ctx.base, data);
}
