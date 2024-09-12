const std = @import("std");
const builtin = @import("builtin");

pub const File = struct {
    data: []align(std.mem.page_size) const u8,
    ctx: Ctx,

    const Ctx = switch (implType()) {
        .posix => CtxPosix,
        .windows => CtxWindows,
    };

    const CtxPosix = struct {};
    const CtxWindows = struct {
        file_handle: std.os.windows.HANDLE,
    };

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

    fn openWindows(path: []const u8, _: std.fs.File.Stat) !@This() {
        var wpath: [std.os.windows.MAX_PATH]u16 = undefined;
        if (path.len > std.os.windows.MAX_PATH) return error.PathTooLong;
        for (path[0..], wpath[0..path.len]) |src, *dst| dst.* = src;

        const handle = try std.os.windows.OpenFile(wpath[0..path.len], .{
            .access_mask = std.os.windows.GENERIC_READ,
            .creation = std.os.windows.FILE_SHARE_READ,
            .share_access = std.os.windows.OPEN_EXISTING,
        });
        _ = handle; // autofix

        @compileError("Unimplemented.");
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

    fn closeWindows(_: @This()) void {
        @compileError("Unimplemented");
    }
};
