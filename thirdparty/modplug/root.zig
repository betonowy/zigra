const std = @import("std");
const c = @cImport(@cInclude("modplug.h"));

pub const File = struct {
    allocator: std.mem.Allocator,

    handle: *c.ModPlugFile,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !@This() {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(data);

        c.ModPlug_SetSettings(&.{
            .mFlags = 0,
            .mChannels = 2,
            .mBits = 32,
            .mFrequency = 44100,
            .mResamplingMode = c.MODPLUG_RESAMPLE_LINEAR,
            .mStereoSeparation = 64,
            .mMaxMixChannels = 32,
            .mReverbDepth = 0,
            .mReverbDelay = 40,
            .mBassAmount = 0,
            .mBassRange = 10,
            .mSurroundDepth = 0,
            .mSurroundDelay = 5,
            .mLoopCount = 0,
        });

        const handle = c.ModPlug_Load(data.ptr, @intCast(data.len)) orelse return error.ModPlugLoadFailed;

        return .{ .handle = handle, .allocator = allocator };
    }

    pub fn deinit(self: @This()) void {
        c.ModPlug_Unload(self.handle);
    }

    pub fn seek(self: @This(), sample: usize) !void {
        c.ModPlug_Seek(self.handle, @intCast(sample / 44));
    }

    pub fn readMono(self: *@This(), samples: []f32) []f32 {
        _ = samples; // autofix
        _ = self; // autofix
        @panic("unimplemented");
    }

    pub fn readStereo(self: *@This(), samples: []@Vector(2, f32)) []@Vector(2, f32) {
        const u32_samples = @as([*]@Vector(2, i32), @ptrCast(samples.ptr))[0..samples.len];

        const read_len: usize = @intCast(c.ModPlug_Read(
            self.handle,
            u32_samples.ptr,
            @intCast(u32_samples.len * @sizeOf(@TypeOf(u32_samples[0]))),
        ));

        const multiplier = 1.0 / @as(f32, 1 << 31);

        for (u32_samples, samples) |u, *f| {
            f.* =
                @as(@Vector(2, f32), @floatFromInt(u)) *
                @Vector(2, f32){ multiplier, multiplier };
        }

        return samples[0 .. read_len / @sizeOf(@TypeOf(samples[0]))];
    }

    pub fn channels(_: *const @This()) u8 {
        return 2;
    }
};
