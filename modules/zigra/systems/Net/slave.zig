const std = @import("std");
const enet = @import("enet");

const Self = @import("../Net.zig");
const zigra = @import("../../root.zig");
const common = @import("common.zig");

pub fn tickBegin(self: *Self, ctx: *zigra.Context, enet_ctx: *enet.HostClient) !void {
    const handler: struct {
        parent: *Self,
        ctx: *zigra.Context,

        pub fn connect(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient) !void {
            try onConnect(handler.parent, handler.ctx, host, id_peer, peer);
        }

        pub fn disconnect(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient) !void {
            try onDisconnect(handler.parent, handler.ctx, host, id_peer, peer);
        }

        pub fn disconnectTimeout(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient) !void {
            try onDisconnect(handler.parent, handler.ctx, host, id_peer, peer);
        }

        pub fn receive(handler: @This(), id_peer: u32, peer: *enet.Peer, host: *enet.HostClient, data: []const u8, channel: u32) !void {
            try onReceive(handler.parent, handler.ctx, host, id_peer, peer, data, channel);
        }
    } = .{ .parent = self, .ctx = ctx };

    try enet_ctx.service(handler);
}

pub fn tickEnd(_: *Self, _: *zigra.Context, enet_ctx: *enet.HostClient) !void {
    enet_ctx.flush();
}

fn onConnect(
    _: *Self,
    _: *zigra.Context,
    _: *enet.HostClient,
    _: u32,
    _: *enet.Peer,
) !void {}

fn onDisconnect(
    _: *Self,
    _: *zigra.Context,
    _: *enet.HostClient,
    _: u32,
    _: *enet.Peer,
) !void {}

fn onReceive(
    self: *Self,
    ctx: *zigra.Context,
    _: *enet.HostClient,
    _: u32,
    _: *enet.Peer,
    data: []const u8,
    channel: u32,
) !void {
    const handler = self.system_handlers.at(channel);
    try handler.recv(&ctx.base, data);
}
