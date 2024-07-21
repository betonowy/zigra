const std = @import("std");

const c = @cImport({
    @cInclude("lz4/lib/lz4.h");
    @cInclude("lz4/lib/lz4hc.h");
});

pub const HcLevel = enum(i32) {
    max = c.LZ4HC_CLEVEL_MAX,
    opt_min = c.LZ4HC_CLEVEL_OPT_MIN,
    default = c.LZ4HC_CLEVEL_DEFAULT,
    min = c.LZ4HC_CLEVEL_MIN,
    _,
};

pub const Variant = union(enum) { lc, hc: HcLevel };

pub fn compress(allocator: std.mem.Allocator, src: []const u8, variant: Variant) !std.ArrayListUnmanaged(u8) {
    const max_possible_size: usize = @intCast(c.LZ4_compressBound(@intCast(src.len)));

    var array = std.ArrayListUnmanaged(u8).fromOwnedSlice(try allocator.alloc(u8, max_possible_size));
    errdefer array.deinit(allocator);

    const final_size = switch (variant) {
        .lc => compressLc(src, array.items),
        .hc => |x| compressHc(src, array.items, x),
    };

    array.shrinkRetainingCapacity(@intCast(final_size));
    return array;
}

fn compressLc(src: []const u8, dst: []u8) i32 {
    const final_size: i32 = @intCast(c.LZ4_compress_default(src.ptr, dst.ptr, @intCast(src.len), @intCast(dst.len)));
    std.debug.assert(final_size != 0);
    return final_size;
}

fn compressHc(src: []const u8, dst: []u8, level: HcLevel) i32 {
    const c_level: c_int = @intFromEnum(level);
    const final_size: i32 = c.LZ4_compress_HC(src.ptr, dst.ptr, @intCast(src.len), @intCast(dst.len), c_level);
    std.debug.assert(final_size != 0);
    return final_size;
}

/// Asserts that dst has the exact size of data about to be decompressed.
pub fn decompress(src: []const u8, dst: []u8) !void {
    if (c.LZ4_decompress_safe(src.ptr, dst.ptr, @intCast(src.len), @intCast(dst.len)) == @as(c_int, @intCast(dst.len))) return;
    return error.InvalidStreamOrExpectedSize;
}

test "compress_decompress_lz4_variants" {
    try testVariant(.lc);
    const hc_begin: usize = @intFromEnum(HcLevel.min);
    const hc_end: usize = @intFromEnum(HcLevel.max) + 1;
    inline for (hc_begin..hc_end) |x| try testVariant(.{ .hc = @enumFromInt(x) });
}

fn testVariant(comptime variant: Variant) !void {
    var test_slice: [1024]u8 = undefined;
    var sfc = std.Random.Sfc64.init(@bitCast(std.time.microTimestamp()));
    sfc.fill(test_slice[0..]);

    var comp_array = try compress(std.testing.allocator, test_slice[0..], variant);
    defer comp_array.deinit(std.testing.allocator);

    const decomp_buf = try std.testing.allocator.alloc(u8, test_slice.len);
    defer std.testing.allocator.free(decomp_buf);
    try decompress(comp_array.items, decomp_buf);

    try std.testing.expectEqualSlices(u8, test_slice[0..], decomp_buf);
}
