const std = @import("std");
const lz4 = @import("lz4");
const c = @cImport(@cInclude("enet.h"));

var global_init_rc = std.atomic.Value(usize).init(0);

fn globalRcInit() !void {
    if (global_init_rc.fetchAdd(1, .acq_rel) != 0) return;
    if (c.enet_initialize() == -1) return error.EnetInit;
}

fn globalRcDeinit() void {
    if (global_init_rc.fetchSub(1, .acq_rel) != 1) return;
    c.enet_deinitialize();
}

// TODO: In the future develop a compressor as data may grow big in this project

// const compressor = struct {
//     pub fn compress(_: ?*anyopaque, in_buffers: [*c]const c.ENetBuffer, in_buffer_count: usize, in_limit: usize, out_data: [*c]c.enet_uint8, out_limit: usize) usize {}
//     pub fn decompress(_: ?*anyopaque, buffer: [*c]const c.ENetBuffer, a: usize, b: usize, d: [*c]c.enet_uint8, s: usize) usize {}
// };

// const EnetCompressor = c.ENetCompressor{
//     .compress = &compressor.compress,
//     .decompress = &compressor.decompress,
//     .context = undefined,
//     .destroy = null,
// };

pub const PacketOptions = struct {
    reliable: bool = false,
    unsequenced: bool = false,

    pub fn toEnetFlags(self: @This()) u32 {
        var flag: u32 = 0;
        if (self.reliable) flag |= c.ENET_PACKET_FLAG_RELIABLE;
        if (self.unsequenced) flag |= c.ENET_PACKET_FLAG_UNSEQUENCED;
        return flag;
    }
};

pub const Peer = c.ENetPeer;

pub const HostServer = struct {
    enet_host: *c.ENetHost,

    pub fn init(host: [:0]const u8, port: u16) !@This() {
        var enet_address = c.ENetAddress{ .port = port };

        if (c.enet_address_set_host(&enet_address, host) == -1) unreachable;
        const enet_host = c.enet_host_create(&enet_address, 8, 8, 0, 0) orelse return error.HostCreate;

        return .{ .enet_host = enet_host };
    }

    pub fn deinit(self: *@This()) void {
        c.enet_host_destroy(self.enet_host);
    }

    pub fn service(self: *@This(), handler: anytype) !void {
        return self.serviceTimeout(handler, 0);
    }

    pub fn serviceTimeout(self: *@This(), handler: anytype, timeout: u32) !void {
        var event: c.ENetEvent = undefined;

        while (c.enet_host_service(self.enet_host, &event, timeout) > 0) {
            switch (event.type) {
                c.ENET_EVENT_TYPE_CONNECT => {
                    try handler.connect(event.peer.*.connectID, event.peer, self);
                },
                c.ENET_EVENT_TYPE_RECEIVE => {
                    defer c.enet_packet_destroy(event.packet);
                    try handler.receive(event.peer.*.connectID, event.peer, self, event.packet.*.data[0..event.packet.*.dataLength], event.channelID);
                },
                c.ENET_EVENT_TYPE_DISCONNECT => {
                    try handler.disconnect(event.peer.*.connectID, event.peer, self);
                },
                c.ENET_EVENT_TYPE_DISCONNECT_TIMEOUT => {
                    try handler.disconnectTimeout(event.peer.*.connectID, event.peer, self);
                },
                else => {},
            }
        }
    }

    pub fn flush(self: *@This()) void {
        c.enet_host_flush(self.enet_host);
    }

    pub fn sendPacket(_: *@This(), peer: *c.ENetPeer, data: []const u8, channel: u8) !void {
        const packet = c.enet_packet_create(data.ptr, data.len, 0) orelse return error.PacketCreate;
        errdefer c.enet_packet_destroy(packet);
        if (c.enet_peer_send(peer, channel, packet) == -1) return error.PeerSend;
    }

    pub fn broadcastPacket(self: *@This(), data: []const u8, channel: u8, options: PacketOptions) !void {
        const packet = c.enet_packet_create(data.ptr, data.len, options.toEnetFlags()) orelse return error.PacketCreate;
        c.enet_host_broadcast(self.enet_host, channel, packet);
    }

    pub fn peers(self: *@This()) []c.ENetPeer {
        return self.enet_host.peers[0..self.enet_host.peerCount];
    }

    pub fn packetMtu(self: *@This()) usize {
        return self.enet_host.mtu - @sizeOf(c.ENetProtocolHeader) - @sizeOf(c.ENetProtocolSendFragment);
    }
};

pub const HostClient = struct {
    enet_host: *c.ENetHost,
    enet_peer: *c.ENetPeer,

    pub fn init(host: [:0]const u8, port: u16) !@This() {
        var enet_address = c.ENetAddress{ .port = port };

        if (c.enet_address_set_host(&enet_address, host) == -1) unreachable;
        const enet_host = c.enet_host_create(null, 8, 0, 0, 0) orelse return error.HostCreate;
        errdefer c.enet_host_destroy(enet_host);

        const enet_peer = c.enet_host_connect(enet_host, &enet_address, 8, 0) orelse return error.HostConnect;

        return .{ .enet_host = enet_host, .enet_peer = enet_peer };
    }

    pub fn deinit(self: *@This()) void {
        c.enet_peer_disconnect(self.enet_peer, 0);
        c.enet_host_destroy(self.enet_host);
    }

    pub fn service(self: *@This(), handler: anytype) !void {
        return self.serviceTimeout(handler, 0);
    }

    pub fn serviceTimeout(self: *@This(), handler: anytype, timeout: u32) !void {
        var event: c.ENetEvent = undefined;

        while (c.enet_host_service(self.enet_host, &event, timeout) > 0) {
            switch (event.type) {
                c.ENET_EVENT_TYPE_CONNECT => {
                    try handler.connect(event.peer.*.connectID, event.peer, self);
                },
                c.ENET_EVENT_TYPE_RECEIVE => {
                    defer c.enet_packet_destroy(event.packet);
                    try handler.receive(event.peer.*.connectID, event.peer, self, event.packet.*.data[0..event.packet.*.dataLength], event.channelID);
                },
                c.ENET_EVENT_TYPE_DISCONNECT => {
                    try handler.disconnect(event.peer.*.connectID, event.peer, self);
                },
                c.ENET_EVENT_TYPE_DISCONNECT_TIMEOUT => {
                    try handler.disconnectTimeout(event.peer.*.connectID, event.peer, self);
                },
                else => {},
            }
        }
    }

    pub fn flush(self: *@This()) void {
        c.enet_host_flush(self.enet_host);
    }

    pub fn disconnect(self: *@This()) void {
        c.enet_peer_disconnect(self.enet_peer, 0);
    }

    pub fn sendPacket(self: *@This(), data: []const u8, channel: u8, options: PacketOptions) !void {
        const packet = c.enet_packet_create(data.ptr, data.len, options.toEnetFlags()) orelse return error.PacketCreate;
        if (c.enet_peer_send(self.enet_peer, channel, packet) == -1) return error.PeerSend;
    }

    pub fn packetMtu(self: *@This()) usize {
        return self.enet_host.mtu - @sizeOf(c.ENetProtocolHeader) - @sizeOf(c.ENetProtocolSendFragment);
    }
};

test "Cool" {
    const Server = struct {
        pub fn run() !void {
            var server = try HostServer.init("127.0.0.1", 7777);
            defer server.deinit();

            const Handler = struct {
                should_disconnect: bool = false,
                timer: std.time.Timer,
                counter: usize = 0,

                fn tp(self: *@This()) f32 {
                    return @as(f32, @floatFromInt(self.timer.read())) / @as(f32, std.time.ns_per_ms);
                }

                pub fn connect(self: *@This(), id_peer: u32, peer: *Peer, host: *HostServer) !void {
                    _ = self; // autofix
                    _ = id_peer; // autofix
                    // std.debug.print("S {d:.3}ms: event connect {}\n", .{ self.tp(), id_peer });
                    try host.sendPacket(peer, "Hello you connected!", 0);
                    // std.debug.print("C mtu: {}\n", .{host.packetMtu()});
                }

                pub fn disconnect(self: *@This(), id_peer: u32, _: *Peer, _: *HostServer) !void {
                    _ = id_peer; // autofix
                    // std.debug.print("S {d:.3}ms: event disconnect {}\n", .{ self.tp(), id_peer });
                    self.should_disconnect = true;
                }

                pub fn disconnectTimeout(self: *@This(), id_peer: u32, _: *Peer, _: *HostServer) !void {
                    _ = id_peer; // autofix
                    // std.debug.print("S {d:.3}ms: event disconnect timeout {}\n", .{ self.tp(), id_peer });
                    self.should_disconnect = true;
                }

                pub fn receive(self: *@This(), id_peer: u32, _: *Peer, host: *HostServer, data: []const u8, channel: u32) !void {
                    _ = id_peer; // autofix
                    _ = data; // autofix
                    // std.debug.print("S {d:.3}ms: event receive: c: {}, d: {s}, {}\n", .{
                    //     self.tp(),
                    //     channel,
                    //     data,
                    //     id_peer,
                    // });

                    switch (channel) {
                        1 => {
                            try host.sendPacket(&host.peers()[0], "Something something", 1);
                            self.counter += 1;

                            if (self.counter == 4) {
                                try host.sendPacket(&host.peers()[0], "Go away", 2);
                            }
                        },
                        else => {},
                    }
                }
            };

            var handler = Handler{ .timer = try std.time.Timer.start() };

            // std.debug.print("S {d:.3}ms: Hosting service\n", .{handler.tp()});
            while (handler.should_disconnect != true) {
                try server.service(&handler);
                if (handler.timer.read() > std.time.ns_per_ms * 5000) break;
            }
            // std.debug.print("S {d:.3}ms: Hosting stopping\n", .{handler.tp()});
        }
    };

    const Client = struct {
        pub fn run() !void {
            var client = try HostClient.init("127.0.0.1", 7777);
            defer client.deinit();

            const Handler = struct {
                timer: std.time.Timer,
                should_disconnect: bool = false,

                fn tp(self: *@This()) f32 {
                    return @as(f32, @floatFromInt(self.timer.read())) / @as(f32, std.time.ns_per_ms);
                }

                pub fn connect(self: *@This(), id_peer: u32, _: *Peer, host: *HostClient) !void {
                    _ = self; // autofix
                    _ = id_peer; // autofix
                    _ = host; // autofix
                    // std.debug.print("C {d:.3}ms: event connect, {}\n", .{ self.tp(), id_peer });
                    // std.debug.print("C mtu: {}\n", .{host.packetMtu()});
                }

                pub fn disconnect(self: *@This(), id_peer: u32, _: *Peer, _: *HostClient) !void {
                    _ = id_peer; // autofix
                    // std.debug.print("C {d:.3}ms: event disconnect {}\n", .{ self.tp(), id_peer });
                    self.should_disconnect = true;
                }

                pub fn disconnectTimeout(self: *@This(), id_peer: u32, _: *Peer, _: *HostClient) !void {
                    _ = id_peer; // autofix
                    // std.debug.print("C {d:.3}ms: event disconnect timeout {}\n", .{ self.tp(), id_peer });
                    self.should_disconnect = true;
                }

                pub fn receive(self: *@This(), id_peer: u32, _: *Peer, host: *HostClient, data: []const u8, channel: u32) !void {
                    _ = id_peer; // autofix
                    _ = data; // autofix
                    // std.debug.print("C {d:.3}ms: event receive: c: {}, d: {s}, {}\n", .{
                    //     self.tp(),
                    //     channel,
                    //     data,
                    //     id_peer,
                    // });

                    c.enet_peer_ping(host.enet_peer);

                    switch (channel) {
                        0 => try host.sendPacket("Hello I'm client", 1, .{}),
                        1 => try host.sendPacket("Something something else", 1, .{}),
                        else => {
                            self.should_disconnect = true;
                        },
                    }
                }
            };

            var handler = Handler{ .timer = try std.time.Timer.start() };

            // std.debug.print("C {d:.3}ms: Connecting to service\n", .{handler.tp()});
            while (handler.should_disconnect != true) {
                try client.service(&handler);
                if (handler.timer.read() > std.time.ns_per_ms * 5000) break;
            }
            // std.debug.print("C {d:.3}ms: Leaving\n", .{handler.tp()});

            // std.debug.print("C round trip: {}\n", .{client.enet_peer.roundTripTime});

            client.disconnect();
            try client.serviceTimeout(&handler, 1);
        }
    };

    const server_thread = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, Server.run, .{});
    defer server_thread.join();

    const client_thread = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, Client.run, .{});
    defer client_thread.join();
}
