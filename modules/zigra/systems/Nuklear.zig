const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

const nk = @import("nuklear");
const nk_vk = @import("Nuklear/vk_backend.zig");
const nk_glfw = @import("Nuklear/glfw_backend.zig");

const glfw = @import("glfw");

const nk_max_mem = 1 * 1024 * 1024;
const nk_mem_alignment = 16;

allocator: std.mem.Allocator,
nk_mem: []u8 = undefined,
nk: nk.Context = undefined,
is_active: bool = false,

window_char_cb: systems.Window.CbCharChild = .{ .cb = &windowCharCb },
window_key_cb: systems.Window.CbKeyChild = .{ .cb = &windowKeyCb },

key_buffer: std.BoundedArray(nk_glfw.KeyEvent, 16) = .{},
char_buffer: std.BoundedArray(u8, 16) = .{},

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn systemInit(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    self.nk_mem = try self.allocator.allocWithOptions(u8, nk_max_mem, nk_mem_alignment, null);

    const Font = struct {
        pub fn textWidth(_: nk.Handle, _: f32, _: [*c]const u8, len: c_int) callconv(.C) f32 {
            return @floatFromInt(8 * len);
        }
    };

    const user_font = nk.UserFont{
        .height = 8,
        .width = &Font.textWidth,
    };

    try nk.initFixed(&self.nk, self.nk_mem, &user_font);

    self.window_char_cb.node.link(&ctx.systems.window.cb_char_root.node);
    self.window_key_cb.node.link(&ctx.systems.window.cb_key_root.node);
}

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.window_char_cb.node.unlink();
    nk.deinit(&self.nk);
    self.allocator.free(self.nk_mem);
}

pub fn inputProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    nk_glfw.processInput(ctx.systems.window.window, &self.nk, self.char_buffer.constSlice(), self.key_buffer.constSlice());
    self.char_buffer.len = 0;
    self.key_buffer.len = 0;
}

pub fn postProcess(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    self.is_active = nk.hasFocus(&self.nk);
}

pub fn render(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try nk.forEachDrawCommand(&self.nk, *zigra.Context, ctx, nk_vk.renderCallback);
    nk.clear(&self.nk);
}

fn windowCharCb(cb: *anyopaque, char: u8) !void {
    const self: *@This() = @fieldParentPtr("window_char_cb", @as(*systems.Window.CbCharChild, @alignCast(@ptrCast(cb))));
    try self.char_buffer.append(char);
}

fn windowKeyCb(cb: *anyopaque, key: glfw.Key, action: glfw.Action) !void {
    const self: *@This() = @fieldParentPtr("window_key_cb", @as(*systems.Window.CbKeyChild, @alignCast(@ptrCast(cb))));
    try self.key_buffer.append(.{ .key = key, .action = action });
}
