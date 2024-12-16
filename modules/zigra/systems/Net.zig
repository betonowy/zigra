const std = @import("std");
const builtin = @import("builtin");

const enet = @import("enet");
const lifetime = @import("lifetime");
const root = @import("../root.zig");
const utils = @import("util");
const tracy = @import("tracy");
const common = @import("common.zig");

const net_master = @import("Net/master.zig");
const net_slave = @import("Net/slave.zig");
const net_common = @import("Net/common.zig");

const Variant = union(enum) {
    master: enet.HostServer,
    slave: enet.HostClient,

    pub fn initMaster(address: [:0]const u8, port: u16) !@This() {
        return .{ .master = try enet.HostServer.init(address, port) };
    }

    pub fn initSlave(address: [:0]const u8, port: u16) !@This() {
        return .{ .slave = try enet.HostClient.init(address, port) };
    }
};

const log = std.log.scoped(.Net);

allocator: std.mem.Allocator,

variant: Variant = undefined,

id_peer: u32 = 0,
id_channel: u8 = undefined,

system_channels: utils.IdArray(Channel),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .system_channels = utils.IdArray(Channel).init(allocator),
    };
}

pub fn systemInit(self: *@This(), _: *root.Modules) anyerror!void {
    if (builtin.os.tag == .windows) return; // This spin of ENet doesn't work on windows...

    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    const address = "127.0.0.1";
    const port = 7777;

    log.info("Initializing master/slave", .{});
    self.variant = Variant.initMaster(address, port) catch try Variant.initSlave(address, port);
    self.id_channel = try self.registerChannel(Channel.init(self));

    switch (self.variant) {
        .master => log.info("Initialized (master)", .{}),
        .slave => log.info("Initialized (slave)", .{}),
    }
}

pub fn deinit(self: *@This()) void {
    if (builtin.os.tag == .windows) return; // This spin of ENet doesn't work on windows...

    var t = common.systemTrace(@This(), @src(), null);
    defer t.end();

    switch (self.variant) {
        .master => |*m| m.deinit(),
        .slave => |*s| s.deinit(),
    }
    self.system_channels.deinit();
}

pub fn tickBegin(self: *@This(), m: *root.Modules) anyerror!void {
    if (builtin.os.tag == .windows) return; // This spin of ENet doesn't work on windows...

    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    switch (self.variant) {
        .master => |*master| try net_master.tickBegin(self, m, master),
        .slave => |*slave| try net_slave.tickBegin(self, m, slave),
    }
}

pub fn tickEnd(self: *@This(), m: *root.Modules) anyerror!void {
    if (builtin.os.tag == .windows) return; // This spin of ENet doesn't work on windows...

    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    switch (self.variant) {
        .master => |*master| try net_master.tickEnd(self, m, master),
        .slave => |*slave| try net_slave.tickEnd(self, m, slave),
    }
}

pub fn isMaster(self: @This()) bool {
    return switch (self.variant) {
        .master => true,
        .slave => false,
    };
}

pub const Channel = struct {
    system: *anyopaque,
    vt_ptr: *const VTable,

    const VTable = struct {
        implRecv: *const fn (*anyopaque, *root.Modules, []const u8) anyerror!void,
        implSyncAll: *const fn (*anyopaque, *root.Modules) anyerror!void,
    };

    pub fn init(struct_ptr: anytype) @This() {
        const interface = struct {
            pub fn recv(self: *anyopaque, m: *root.Modules, data: []const u8) !void {
                const name = "netRecv";
                if (!std.meta.hasMethod(@TypeOf(struct_ptr.*), name)) return;
                try @field(@TypeOf(struct_ptr.*), name)(@alignCast(@ptrCast(self)), m, data);
            }

            pub fn syncAll(self: *anyopaque, m: *root.Modules) !void {
                const name = "netSyncAll";
                if (!std.meta.hasMethod(@TypeOf(struct_ptr.*), name)) return;
                try @field(@TypeOf(struct_ptr.*), name)(@alignCast(@ptrCast(self)), m);
            }
        };

        return .{ .system = struct_ptr, .vt_ptr = comptime &VTable{
            .implRecv = &interface.recv,
            .implSyncAll = &interface.syncAll,
        } };
    }

    pub fn recv(self: @This(), m: *root.Modules, data: []const u8) !void {
        try self.vt_ptr.implRecv(self.system, m, data);
    }

    pub fn syncAll(self: @This(), m: *root.Modules) !void {
        try self.vt_ptr.implSyncAll(self.system, m);
    }
};

pub fn registerChannel(self: *@This(), channel: Channel) !u8 {
    return @intCast(try self.system_channels.put(channel));
}

pub fn unregisterChannel(self: *@This(), id_handler: u8) void {
    self.system_channels.remove(id_handler);
}

pub fn send(self: *@This(), id_channel: u8, data: []const u8, options: enet.PacketOptions) !void {
    try switch (self.variant) {
        .master => |*m| net_master.send(m, @intCast(id_channel), data, options),
        .slave => |*s| net_slave.send(s, @intCast(id_channel), data, options),
    };
}

pub fn netRecv(self: *@This(), m: *root.Modules, data: []const u8) !void {
    var stream = std.io.fixedBufferStream(data);

    switch (try stream.reader().readEnum(net_common.PacketType, .little)) {
        .connection_data => {
            tracy.message("(Net) connection data");

            if (self.isMaster()) return error.InvalidNetRole;

            const connection_data = try stream.reader().readStructEndian(net_common.ConnectionData, .little);

            self.id_peer = connection_data.id_peer;
            log.info("Synced connection data, connection ID: {}", .{self.id_peer});

            try self.send(self.id_channel, std.mem.asBytes(&net_common.PacketType.sync_all), .{ .reliable = true });
        },
        .sync_all => {
            tracy.message("(Net) sync all");
            log.info("Received sync all request", .{});

            var iterator = self.system_channels.iterator();
            while (iterator.next()) |channel| try channel.syncAll(m);
        },
    }

    if (stream.pos != data.len) log.info("{} bytes unread from net packet", .{data.len - stream.pos});
}
