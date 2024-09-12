const std = @import("std");
const utils = @import("utils");
const tracy = @import("tracy");

const Audio = @import("../Audio.zig");
const Channel = @import("Channel.zig");
const streams = @import("streams.zig");

const log = std.log.scoped(.Mixer);

const sound_channel_count = 4;
const request_queue_len = 128;
const event_queue_len = 128;

allocator: std.mem.Allocator,
requests: utils.mt.SpScQueue(Request),
events: utils.mt.SpScQueue(Event),

music: ?Channel = null,
channels: [sound_channel_count]?Channel = .{null} ** sound_channel_count,

listener_pos: @Vector(2, f32) = .{ 0, 0 },
listener_range: f32 = 320, // should be screen width
master_volume: f32 = 1,

process_samples_scratch_buf: std.ArrayList(@Vector(2, f32)),

// We never want to block mixer thread, so we should
// submit requests to it via a SpSc queue of requests
// whenever we want to mutate it's state so that it can
// handle it on its own pace without blocking.
pub const Request = union(enum) {
    play_music: struct { id_sound: u32 },
    play_sound: struct { id_sound: u32 },
    set_listener_pos: struct { pos: @Vector(2, f32) },
    set_listener_range: struct { range: f32 },
};

// Like requests, mixer posts events that
// need to be handled via SpSc queue.
//
// TODO Not used for anything yet
pub const Event = union(enum) {
    music_ended: struct { id_sound: u32 },
};

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .process_samples_scratch_buf = std.ArrayList(@Vector(2, f32)).init(allocator),
        .requests = try utils.mt.SpScQueue(Request).init(allocator, request_queue_len),
        .events = try utils.mt.SpScQueue(Event).init(allocator, event_queue_len),
    };
}

pub fn deinit(self: *@This()) void {
    if (self.music) |*music| music.deinit();
    for (self.channels[0..]) |*opt| if (opt.*) |*c| c.deinit();
    self.requests.deinit(self.allocator);
    self.events.deinit(self.allocator);
    self.process_samples_scratch_buf.deinit();
}

fn parent(self: *@This()) *Audio {
    return @fieldParentPtr("mixer", self);
}

pub fn playMusic(self: *@This(), id_sound: u32) !void {
    try self.requests.push(.{ .play_music = .{ .id_sound = id_sound } });
}

pub fn playSound(self: *@This(), id_sound: u32) !void {
    try self.requests.push(.{ .play_sound = .{ .id_sound = id_sound } });
}

pub fn setListenerPos(self: *@This(), pos: @Vector(2, f32)) !void {
    try self.requests.push(.{ .set_listener_pos = .{ .pos = pos } });
}

pub fn setListenerRange(self: *@This(), range: f32) !void {
    try self.requests.push(.{ .set_listener_range = .{ .range = range } });
}

pub fn getNextSamples(self: *@This(), samples: []@Vector(2, f32)) void {
    self.handlePendingRequests() catch |e| {
        log.err("Error during request processing: {}", .{e});
        if (@errorReturnTrace()) |st| std.debug.dumpStackTrace(st);
    };
    self.processSamples(samples);
}

fn handlePendingRequests(self: *@This()) !void {
    const trace = tracy.trace(@src());
    defer trace.end();

    while (self.requests.pop()) |request| switch (request) {
        .play_music => |r| {
            const stream = self.parent().streams.at(r.id_sound);
            if (self.music) |*music| music.deinit();
            self.music = Channel.init(
                stream.reader(),
                .{ .repeat = std.math.maxInt(usize) },
            );
        },
        .play_sound => |r| {
            const stream = self.parent().streams.at(r.id_sound);

            const channel = self.getFreeChannel() orelse {
                log.err("No free channels at the moment", .{});
                continue;
            };

            channel.* = Channel.init(stream.reader(), .{});
        },
        .set_listener_pos => |r| self.listener_pos = r.pos,
        .set_listener_range => |r| self.listener_range = r.range,
    };
}

fn processSamples(self: *@This(), samples: []@Vector(2, f32)) void {
    const trace = tracy.trace(@src());
    defer trace.end();

    self.process_samples_scratch_buf.resize(samples.len) catch |e| {
        utils.tried.panic(e, @errorReturnTrace());
    };

    const scratch_samples = self.process_samples_scratch_buf.items;

    if (self.music) |*music| brk: {
        music.mixSamples(.replace, samples, scratch_samples, .{ 0, 0 }, self.listener_range);
        if (!music.isFinished()) break :brk;

        // TODO think about what id here is useful
        self.events.push(.{ .music_ended = .{ .id_sound = 0 } }) catch |e| {
            log.err("Failed to push music_ended event {}", .{e});
        };

        music.deinit();
        self.music = null;
    }

    for (&self.channels) |*opt| if (opt.*) |*c| {
        c.mixSamples(.add, samples, scratch_samples, self.listener_pos, self.listener_range);
        if (!c.isFinished()) continue;
        c.deinit();
        opt.* = null;
    };

    for (samples) |*sample| sample.* *= @splat(self.master_volume);
}

fn getFreeChannel(self: *@This()) ?*?Channel {
    for (self.channels[0..]) |*channel| if (channel.* == null) return channel;
    return null;
}
