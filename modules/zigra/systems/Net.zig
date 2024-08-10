const std = @import("std");

const enet = @import("enet");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");
const utils = @import("utils");

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
id_net: u32 = undefined,

system_handlers: utils.IdArray(Handler),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .system_handlers = utils.IdArray(Handler).init(allocator),
    };
}

pub fn systemInit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    const address = "127.0.0.1";
    const port = 7777;

    log.info("Initializing master/slave", .{});
    self.variant = Variant.initMaster(address, port) catch try Variant.initSlave(address, port);
    self.id_net = try self.registerSystemHandler(Handler.init(self, .netRecv));

    switch (self.variant) {
        .master => log.info("Initialized (master)", .{}),
        .slave => log.info("Initialized (slave)", .{}),
    }
}

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    log.info("Deinitializing", .{});
    self.system_handlers.deinit();

    switch (self.variant) {
        .master => |*m| m.deinit(),
        .slave => |*s| s.deinit(),
    }
}

pub fn tickBegin(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    switch (self.variant) {
        .master => |*m| try master.tickBegin(self, ctx, m),
        .slave => |*s| try slave.tickBegin(self, ctx, s),
    }
}

pub fn tickEnd(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    switch (self.variant) {
        .master => |*m| try master.tickEnd(self, ctx, m),
        .slave => |*s| try slave.tickEnd(self, ctx, s),
    }
}

pub fn deinit(_: *@This()) void {}

pub const Handler = struct {
    system: *anyopaque,
    function_ptr: *const fn (*anyopaque, *lifetime.ContextBase, []const u8) anyerror!void,

    pub fn init(struct_ptr: anytype, comptime function_tag: anytype) @This() {
        const method = @field(@TypeOf(struct_ptr.*), @tagName(function_tag));

        const helper = struct {
            pub fn recv(self: *anyopaque, ctx: *lifetime.ContextBase, data: []const u8) !void {
                try method(@alignCast(@ptrCast(self)), ctx, data);
            }
        };

        return .{ .system = struct_ptr, .function_ptr = &helper.recv };
    }

    pub fn recv(self: @This(), ctx: *lifetime.ContextBase, data: []const u8) !void {
        try self.function_ptr(self.system, ctx, data);
    }
};

pub fn registerSystemHandler(self: *@This(), handler: Handler) !u32 {
    return try self.system_handlers.put(handler);
}

pub fn unregisterSystemHandler(self: *@This(), id_handler: u32) void {
    self.system_handlers.remove(id_handler);
}

pub fn send(self: @This(), id_handler: u32) !void {
    _ = id_handler; // autofix
    _ = self; // autofix
}

pub fn netRecv(self: *@This(), _: *lifetime.ContextBase, data: []const u8) !void {
    var stream = std.io.fixedBufferStream(data);

    switch (try stream.reader().readEnum(common.PacketType, .little)) {
        .connection_data => {
            const connection_data = try stream.reader().readStructEndian(common.ConnectionData, .little);
            self.id_peer = connection_data.id_peer;
        },
    }

    if (stream.pos != data.len) log.info("{} bytes unread from packet", .{data.len - stream.pos});
}
