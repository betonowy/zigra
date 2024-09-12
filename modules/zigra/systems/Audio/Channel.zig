const std = @import("std");
const streams = @import("streams.zig");
const la = @import("la");
const builtin = @import("builtin");

source: streams.Stream.Reader,
state: State,
uuid: usize,

pub const State = struct {
    repeat: usize = 1,
    pos: ?@Vector(2, f32) = null,
    pitch: f32 = 1,
    volume: f32 = 1,
    pan_volume_last: ?@Vector(2, f32) = null,
};

fn generateChannelUuid() usize {
    const state = struct {
        var counter: usize = 0;
    };

    defer state.counter +%= 1;
    return state.counter;
}

pub fn init(source: streams.Stream.Reader, init_state: State) @This() {
    return .{ .source = source, .state = init_state, .uuid = generateChannelUuid() };
}

pub fn deinit(self: *@This()) void {
    self.source.deinit();
    self.* = undefined;
}

pub const MixSamplesMethod = enum { add, replace };

pub fn mixSamples(
    self: *@This(),
    comptime method: MixSamplesMethod,
    samples: []@Vector(2, f32),
    scratch_samples: []@Vector(2, f32),
    listener_pos: @Vector(2, f32),
    listener_inv_range: f32,
) void {
    self.fillSamples(scratch_samples);
    self.processSamples(scratch_samples, self.calculateRelativePos(listener_pos, listener_inv_range));

    for (samples, scratch_samples) |*dst, src| switch (method) {
        .add => dst.* += src,
        .replace => dst.* = src,
    };
}

pub fn isFinished(self: *@This()) bool {
    return self.state.repeat == 0;
}

fn fillSamples(self: *@This(), samples: []@Vector(2, f32)) void {
    if (self.isFinished()) return @memset(samples, .{ 0, 0 });

    const filled_slice = self.source.readStereo(samples);

    if (filled_slice.len < samples.len) {
        self.state.repeat -= 1;
        self.source.seek(0) catch unreachable;
        self.fillSamples(samples[filled_slice.len..]);
    }
}

fn processSamples(self: *@This(), samples: []@Vector(2, f32), relative_pos: @Vector(2, f32)) void {
    const pan_volume_next = panVolume(relative_pos);
    const pan_volume_last = self.state.pan_volume_last orelse pan_volume_next;

    for (samples, 0..) |*sample, i| {
        const pan_volume_crossover = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples.len));

        const pan_volume_effective =
            pan_volume_last * la.splat(2, 1 - pan_volume_crossover) +
            pan_volume_next * la.splat(2, pan_volume_crossover);

        sample.* *= pan_volume_effective;
    }

    self.state.pan_volume_last = pan_volume_next;
}

fn panVolume(relative_pos: @Vector(2, f32)) @Vector(2, f32) {
    const popular_case = @Vector(2, f32){ 0, 0 };

    if (@reduce(.And, relative_pos == popular_case)) {
        return comptime panVolumeCalc(popular_case);
    } else {
        return panVolumeCalc(relative_pos);
    }
}

fn panVolumeCalc(relative_pos: @Vector(2, f32)) @Vector(2, f32) {
    const pan = @Vector(2, f32){
        1 / (1 + @exp(relative_pos[0])),
        1 / (1 + @exp(-relative_pos[0])),
    };

    const volume = 1 / (1 + la.sqrLength(relative_pos));

    return pan * la.splat(2, volume);
}

fn calculateRelativePos(self: *@This(), listener_pos: @Vector(2, f32), listener_inv_range: f32) @Vector(2, f32) {
    const source_pos = self.state.pos orelse return .{ 0, 0 };
    return (source_pos - listener_pos) * la.splat(2, listener_inv_range);
}
