const nk = @import("nuklear");
const zigra = @import("../../root.zig");
const Window = @import("../Window.zig");
const std = @import("std");
const glfw = @import("glfw");

pub const KeyEvent = struct {
    key: glfw.Key,
    action: glfw.Action,
};

pub fn processInput(window: glfw.Window, ctx: *nk.Context, chars: []const u21, keys: []const KeyEvent) void {
    nk.inputBegin(ctx);
    defer nk.inputEnd(ctx);

    const cursor_pos = window.getCursorPos();
    const lmb = window.getMouseButton(.left);
    const rmb = window.getMouseButton(.left);

    nk.inputMotion(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos));
    nk.inputButton(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos), nk.button_left, lmb != .release);
    nk.inputButton(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos), nk.button_right, rmb != .release);
    nk.inputChars(ctx, chars);

    for (keys) |key| switch (key.key) {
        else => {},
        .backspace => nk.inputKey(ctx, nk.KEY_BACKSPACE, key.action != .release),
    };

    if (!nk.hasFocus(ctx)) return;

    var glfw_ptr = window.getUserPointer(Window.GlfwCbCtx) orelse unreachable;

    nk.inputScroll(ctx, glfw_ptr.x_scroll, glfw_ptr.y_scroll);
    glfw_ptr.x_scroll = 0;
    glfw_ptr.y_scroll = 0;
}
