const std = @import("std");
const utils = @import("utils");
// const la = @import("la");

const zaudio = @import("zaudio");
const lifetime = @import("lifetime");
// const zigra = @import("../root.zig");
const tracy = @import("tracy");

const res_list = @import("Audio/res_list.zig");
const streams = @import("Audio/streams.zig");
const Mixer = @import("Audio/Mixer.zig");

allocator: std.mem.Allocator,
device: *zaudio.Device = undefined,
mixer: Mixer,

streams: utils.IdArray(streams.Stream),
streams_slut: std.StringHashMap(u32),

pub fn init(allocator: std.mem.Allocator) !@This() {
    zaudio.init(allocator);
    return .{
        .allocator = allocator,
        .streams = utils.IdArray(streams.Stream).init(allocator),
        .streams_slut = std.StringHashMap(u32).init(allocator),
        .mixer = try Mixer.init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.mixer.deinit();
    var iterator = self.streams.iterator();
    while (iterator.next()) |stream| stream.deinit();
    self.streams.deinit();
    self.streams_slut.deinit();
    zaudio.deinit();
}

pub fn systemInit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.device = device: {
        var config = zaudio.Device.Config.init(.playback);
        config.data_callback = audioCallback;
        config.user_data = self;
        config.sample_rate = 44_100;
        config.period_size_in_frames = 256;
        config.period_size_in_milliseconds = 10;
        config.playback.format = .float32;
        config.playback.channels = 2;
        break :device try zaudio.Device.create(null, config);
    };
    errdefer self.device.destroy();

    try self.loadResources();

    try self.device.start();
}

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    try self.device.stop();
    self.device.destroy();
}

pub fn loadResources(self: *@This()) !void {
    for (res_list.sounds) |sound_path| {
        const id = try self.streams.put(try streams.Stream.initFromFile(self.allocator, sound_path, .{ .stream = false }));
        try self.streams_slut.put(sound_path, id);
    }

    for (res_list.music) |music_path| {
        const id = try self.streams.put(try streams.Stream.initFromFile(self.allocator, music_path, .{ .stream = true }));
        try self.streams_slut.put(music_path, id);
    }
}

fn audioCallback(device: *zaudio.Device, output: ?*anyopaque, _: ?*const anyopaque, num_frames: u32) callconv(.C) void {
    const trace = tracy.trace(@src());
    defer trace.end();

    const audio = @as(*@This(), @ptrCast(@alignCast(device.getUserData())));
    const samples = @as([*]@Vector(2, f32), @ptrCast(@alignCast(output)))[0..num_frames];

    audio.mixer.getNextSamples(samples);
}
