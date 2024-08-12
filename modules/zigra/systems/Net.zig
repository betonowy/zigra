const std = @import("std");

const enet = @import("enet");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");
const utils = @import("utils");
const tracy = @import("tracy");

const master = @import("Net/master.zig");
const slave = @import("Net/slave.zig");
const common = @import("Net/common.zig");

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

pub fn systemInit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
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

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    log.info("Deinitializing", .{});

    switch (self.variant) {
        .master => |*m| m.deinit(),
        .slave => |*s| s.deinit(),
    }
}

pub fn tickBegin(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const trace = tracy.trace(@src());
    trace.end();

    const ctx = ctx_base.parent(zigra.Context);

    switch (self.variant) {
        .master => |*m| try master.tickBegin(self, ctx, m),
        .slave => |*s| try slave.tickBegin(self, ctx, s),
    }
}

pub fn tickEnd(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const trace = tracy.trace(@src());
    trace.end();

    const ctx = ctx_base.parent(zigra.Context);

    switch (self.variant) {
        .master => |*m| try master.tickEnd(self, ctx, m),
        .slave => |*s| try slave.tickEnd(self, ctx, s),
    }
}

pub fn deinit(self: *@This()) void {
    self.system_channels.deinit();
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
        implRecv: *const fn (*anyopaque, *lifetime.ContextBase, []const u8) anyerror!void,
        implSyncAll: *const fn (*anyopaque, *lifetime.ContextBase) anyerror!void,
    };

    pub fn init(struct_ptr: anytype) @This() {
        const interface = struct {
            pub fn recv(self: *anyopaque, ctx: *lifetime.ContextBase, data: []const u8) !void {
                const name = "netRecv";
                if (!std.meta.hasMethod(@TypeOf(struct_ptr.*), name)) return;
                try @field(@TypeOf(struct_ptr.*), name)(@alignCast(@ptrCast(self)), ctx, data);
            }

            pub fn syncAll(self: *anyopaque, ctx: *lifetime.ContextBase) !void {
                const name = "netSyncAll";
                if (!std.meta.hasMethod(@TypeOf(struct_ptr.*), name)) return;
                try @field(@TypeOf(struct_ptr.*), name)(@alignCast(@ptrCast(self)), ctx);
            }
        };

        return .{ .system = struct_ptr, .vt_ptr = comptime &VTable{
            .implRecv = &interface.recv,
            .implSyncAll = &interface.syncAll,
        } };
    }

    pub fn recv(self: @This(), ctx: *lifetime.ContextBase, data: []const u8) !void {
        try self.vt_ptr.implRecv(self.system, ctx, data);
    }

    pub fn syncAll(self: @This(), ctx: *lifetime.ContextBase) !void {
        try self.vt_ptr.implSyncAll(self.system, ctx);
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
        .master => |*m| master.send(m, @intCast(id_channel), data, options),
        .slave => |*s| slave.send(s, @intCast(id_channel), data, options),
    };
}

pub fn netRecv(self: *@This(), ctx: *lifetime.ContextBase, data: []const u8) !void {
    var stream = std.io.fixedBufferStream(data);

    switch (try stream.reader().readEnum(common.PacketType, .little)) {
        .connection_data => {
            tracy.message("(Net) connection data");

            if (self.isMaster()) return error.InvalidNetRole;

            const connection_data = try stream.reader().readStructEndian(common.ConnectionData, .little);

            self.id_peer = connection_data.id_peer;
            log.info("Synced connection data, connection ID: {}", .{self.id_peer});

            try self.send(self.id_channel, std.mem.asBytes(&common.PacketType.sync_all), .{ .reliable = true });
        },
        .sync_all => {
            tracy.message("(Net) sync all");
            log.info("Received sync all request", .{});

            var iterator = self.system_channels.iterator();
            while (iterator.next()) |channel| try channel.syncAll(ctx);
        },
    }

    if (stream.pos != data.len) log.info("{} bytes unread from net packet", .{data.len - stream.pos});
}
