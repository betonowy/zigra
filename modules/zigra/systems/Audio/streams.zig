const std = @import("std");
const stb = @import("stb");

pub const Stream = struct {
    variant: union(enum) {
        mem: MemoryStream,
        file: FileStream,
    },

    pub const InitOptions = struct {
        stream: bool = false,
    };

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8, options: InitOptions) !@This() {
        if (options.stream) {
            return .{ .variant = .{ .file = try FileStream.initFromFile(allocator, path) } };
        } else {
            return .{ .variant = .{ .mem = try MemoryStream.initFromFile(allocator, path) } };
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.variant) {
            .mem => |*m| m.deinit(),
            .file => |*f| f.deinit(),
        }
    }

    pub fn reader(self: *@This()) Reader {
        return switch (self.variant) {
            .mem => |*m| m.reader(),
            .file => |*f| f.reader(),
        };
    }

    pub const Reader = struct {
        variant: union(enum) {
            mem: MemoryStream.Reader,
            file: FileStream.Reader,
        },

        pub fn deinit(self: *@This()) void {
            switch (self.variant) {
                .mem => |*m| m.deinit(),
                .file => |*f| f.deinit(),
            }
        }

        pub fn seek(self: *@This(), sample: usize) !void {
            return switch (self.variant) {
                .mem => |*m| m.seek(sample),
                .file => |*f| f.seek(sample),
            };
        }

        pub fn reset(self: *@This()) void {
            self.seek(0) catch unreachable;
        }

        pub fn readMono(self: *@This(), samples: []f32) []f32 {
            return switch (self.variant) {
                .mem => |*m| m.readMono(samples),
                .file => |*f| f.readMono(samples),
            };
        }

        pub fn readStereo(self: *@This(), samples: []@Vector(2, f32)) []@Vector(2, f32) {
            return switch (self.variant) {
                .mem => |*m| m.readStereo(samples),
                .file => |*f| f.readStereo(samples),
            };
        }

        pub fn channels(self: *const @This()) u8 {
            return switch (self.variant) {
                .mem => |*m| m.channels(),
                .file => |*f| f.channels(),
            };
        }
    };
};

const MemoryStream = struct {
    allocator: std.mem.Allocator,
    buffer: union(enum) {
        mono: []f32,
        stereo: []@Vector(2, f32),
    },

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !@This() {
        var vorbis = try stb.Vorbis.initFile(allocator, path);
        defer vorbis.deinit();

        const self: @This() = .{
            .allocator = allocator,
            .buffer = switch (vorbis.info.channels) {
                1 => .{ .mono = try allocator.alloc(f32, vorbis.info.len_in_samples) },
                2 => .{ .stereo = try allocator.alloc(@Vector(2, f32), vorbis.info.len_in_samples) },
                else => return error.UnsupportedChannelCount,
            },
        };

        switch (self.buffer) {
            .mono => |buf| std.debug.assert(vorbis.decodeMono(buf).len == buf.len),
            .stereo => |buf| std.debug.assert(vorbis.decodeStereo(buf).len == buf.len),
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        switch (self.buffer) {
            .mono => |buf| self.allocator.free(buf),
            .stereo => |buf| self.allocator.free(buf),
        }
    }

    pub fn reader(self: *@This()) Stream.Reader {
        return .{ .variant = .{ .mem = .{ .parent = self } } };
    }

    pub const Reader = struct {
        parent: *MemoryStream,
        cursor: usize = 0,

        pub fn deinit(_: *@This()) void {}

        pub fn seek(self: *@This(), sample: usize) !void {
            switch (self.parent.buffer) {
                .mono => |buf| if (sample >= buf.len) return error.SeekError,
                .stereo => |buf| if (sample >= buf.len) return error.SeekError,
            }
            self.cursor = sample;
        }

        pub fn readMono(self: *@This(), samples: []f32) []f32 {
            switch (self.parent.buffer) {
                .mono => |buf| {
                    const available = buf[self.cursor..];
                    const read_len = @min(samples.len, available.len);
                    @memcpy(samples[0..read_len], available[0..read_len]);
                    self.cursor += read_len;
                    return samples[0..read_len];
                },
                .stereo => |buf| {
                    const available = buf[self.cursor..];
                    const read_len = @min(samples.len, available.len);
                    for (buf, samples) |src, *dst| dst.* = @reduce(.Add, src) * 0.5;
                    self.cursor += read_len;
                    return samples[0..read_len];
                },
            }
        }

        pub fn readStereo(self: *@This(), samples: []@Vector(2, f32)) []@Vector(2, f32) {
            switch (self.parent.buffer) {
                .mono => |buf| {
                    const available = buf[self.cursor..];
                    const read_len = @min(samples.len, available.len);
                    for (samples[0..read_len], available[0..read_len]) |*dst, src| dst.* = @splat(src);
                    self.cursor += read_len;
                    return samples[0..read_len];
                },
                .stereo => |buf| {
                    const available = buf[self.cursor..];
                    const read_len = @min(samples.len, available.len);
                    @memcpy(samples[0..read_len], available[0..read_len]);
                    self.cursor += read_len;
                    return samples[0..read_len];
                },
            }
        }

        pub fn channels(self: *const @This()) u8 {
            return switch (self.parent.buffer) {
                .mono => 1,
                .stereo => 2,
            };
        }
    };
};

const FileStream = struct {
    vorbis: stb.Vorbis,
    users: usize = 0,

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !@This() {
        return .{ .vorbis = try stb.Vorbis.initFile(allocator, path) };
    }

    pub fn deinit(self: *@This()) void {
        if (self.users > 0) unreachable;
        self.vorbis.deinit();
    }

    pub fn reader(self: *@This()) Stream.Reader {
        if (self.users != 0) unreachable;
        self.users += 1;
        return .{ .variant = .{ .file = .{ .parent = self } } };
    }

    pub const Reader = struct {
        parent: *FileStream,

        pub fn deinit(self: *@This()) void {
            self.parent.users -= 1;
        }

        pub fn seek(self: *@This(), sample: usize) !void {
            try self.parent.vorbis.seek(@intCast(sample));
        }

        pub fn readMono(self: *@This(), samples: []f32) []f32 {
            return self.parent.vorbis.decodeMono(samples);
        }

        pub fn readStereo(self: *@This(), samples: []@Vector(2, f32)) []@Vector(2, f32) {
            return self.parent.vorbis.decodeStereo(samples);
        }

        pub fn channels(self: *const @This()) u8 {
            return self.parent.vorbis.info.channels;
        }
    };
};

// TODO libxm is probably a good enough candidate to implement that
//
// const XmStream = struct {
//     xm_stream: void,

//     pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !@This() {
//         _ = allocator; // autofix
//         _ = path; // autofix
//     }
// };
