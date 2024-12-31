const std = @import("std");
const util = @import("util");

const c = @cImport({
    @cDefine("STB_VORBIS_HEADER_ONLY", {});
    @cInclude("stb/stb_vorbis.c");
});

pub const Vorbis = struct {
    allocator: std.mem.Allocator,
    ctx: *c.stb_vorbis,
    file: util.mio.File,
    vorbis_memory: []const u8,
    info: struct {
        channels: u8,
        sample_rate: u32,
        len_in_samples: u32,
        len_in_seconds: f32,
    },

    pub fn initFile(allocator: std.mem.Allocator, path: []const u8) !@This() {
        const file = try util.mio.File.open(path);
        errdefer file.close();

        const vorbis_memory = try allocator.alloc(u8, 1024 * 1024);
        errdefer allocator.free(vorbis_memory);

        var err: c_int = undefined;

        const ctx: *c.stb_vorbis = c.stb_vorbis_open_memory(
            file.data.ptr,
            @intCast(file.data.len),
            &err,
            &.{
                .alloc_buffer = vorbis_memory.ptr,
                .alloc_buffer_length_in_bytes = @intCast(vorbis_memory.len),
            },
        ) orelse return error.StbVorbisOpenFailed;

        const vorbis_info = c.stb_vorbis_get_info(ctx);
        const samples = c.stb_vorbis_stream_length_in_samples(ctx);
        const seconds = c.stb_vorbis_stream_length_in_seconds(ctx);

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .file = file,
            .vorbis_memory = vorbis_memory,
            .info = .{
                .channels = @intCast(vorbis_info.channels),
                .sample_rate = @intCast(vorbis_info.sample_rate),
                .len_in_samples = samples,
                .len_in_seconds = seconds,
            },
        };
    }

    pub fn deinit(self: @This()) void {
        c.stb_vorbis_close(self.ctx);
        self.allocator.free(self.vorbis_memory);
        self.file.close();
    }

    pub fn decodeStereo(self: @This(), samples: []@Vector(2, f32)) []@Vector(2, f32) {
        std.debug.assert(self.info.channels == 2);
        const sample_count = c.stb_vorbis_get_samples_float_interleaved(self.ctx, 2, @ptrCast(samples.ptr), @intCast(samples.len * 2));
        if (sample_count == 0) return &.{};
        return samples[0..@intCast(sample_count)];
    }

    pub fn decodeMono(self: @This(), samples: []f32) []f32 {
        std.debug.assert(self.info.channels == 1);
        const sample_count = c.stb_vorbis_get_samples_float_interleaved(self.ctx, 1, @ptrCast(samples.ptr), @intCast(samples.len * 2));
        if (sample_count == 0) return &.{};
        return samples[0..@intCast(sample_count)];
    }

    pub fn seek(self: @This(), sample: u32) !void {
        if (c.stb_vorbis_seek(self.ctx, @intCast(sample)) == 0) return error.StbVorbisSeekError;
    }
};
