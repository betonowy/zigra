const std = @import("std");
const enet = @import("enet");

const Self = @import("../Net.zig");
const root = @import("../../root.zig");
const common = @import("common.zig");

const log = std.log.scoped(.NetSlave);

pub fn tickBegin(self: *Self, m: *root.Modules, ctx: *enet.HostClient) !void {
    const handler: struct {
        parent: *Self,
        m: *root.Modules,

        pub fn connect(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient) !void {
            try onConnect(handler.parent, handler.m, host, id_peer, peer);
        }

        pub fn disconnect(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient) !void {
            try onDisconnect(handler.parent, handler.m, host, id_peer, peer);
        }

        pub fn disconnectTimeout(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient) !void {
            try onDisconnect(handler.parent, handler.m, host, id_peer, peer);
        }

        pub fn receive(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient, data: []const u8, channel: u32) !void {
            try onReceive(handler.parent, handler.m, host, id_peer, peer, data, channel);
        }
    } = .{ .parent = self, .m = m };

    try ctx.service(handler);
}

pub fn tickEnd(_: *Self, _: *root.Modules, ctx: *enet.HostClient) !void {
    ctx.flush();
}

pub fn send(ctx: *enet.HostClient, id_channel: u8, data: []const u8, options: enet.PacketOptions) !void {
    try ctx.sendPacket(data, id_channel, options);
}

fn onConnect(_: *Self, _: *root.Modules, _: *enet.HostClient, _: u32, _: *enet.Peer) !void {}

fn onDisconnect(_: *Self, _: *root.Modules, _: *enet.HostClient, id_peer: u32, _: *enet.Peer) !void {
    log.info("Master disconnected: {}", .{id_peer});
}

fn onReceive(self: *Self, m: *root.Modules, _: *enet.HostClient, _: u32, _: *enet.Peer, data: []const u8, channel: u32) !void {
    const handler = self.system_channels.at(channel);
    try handler.recv(m, data);
}
