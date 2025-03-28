const std = @import("std");
const builtin = @import("builtin");

pub const File = struct {
    const SliceType = switch (implType()) {
        .posix => []align(std.heap.page_size_min) const u8,
        .windows => []const u8,
    };

    data: SliceType,
    ctx: Ctx,

    const Ctx = switch (implType()) {
        .posix => CtxPosix,
        .windows => CtxWindows,
    };

    const CtxPosix = struct {};
    const CtxWindows = struct {}; // TODO Actual MIO

    const ImplType = enum { posix, windows };

    pub fn implType() ImplType {
        return switch (builtin.os.tag) {
            .linux, .macos, .plan9 => .posix,
            .windows => .windows,
            else => @compileError("Unsupported system"),
        };
    }

    pub fn open(path: []const u8) !@This() {
        return switch (comptime implType()) {
            .posix => openPosix(path),
            .windows => openWindows(path),
        };
    }

    fn openPosix(path: []const u8) !@This() {
        const fd = try std.posix.open(path, .{}, @intFromEnum(std.posix.ACCMODE.RDONLY));
        defer std.posix.close(fd);

        const stat = try std.posix.fstat(fd);

        return .{
            .data = try std.posix.mmap(null, @intCast(stat.size), std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0),
            .ctx = .{},
        };
    }

    fn openWindows(path: []const u8) !@This() { // TODO Actual MIO
        return .{
            .data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, std.math.maxInt(usize)),
            .ctx = .{},
        };
    }

    pub fn close(self: @This()) void {
        switch (comptime implType()) {
            .posix => self.closePosix(),
            .windows => self.closeWindows(),
        }
    }

    fn closePosix(self: @This()) void {
        std.posix.munmap(self.data);
    }

    fn closeWindows(self: @This()) void { // TODO Actual MIO
        std.heap.page_allocator.free(self.data);
    }
};
