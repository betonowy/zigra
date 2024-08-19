const nk = @import("nuklear");
const zigra = @import("../../root.zig");
const Window = @import("../Window.zig");
const vk_types = @import("../Vulkan/types.zig");
const std = @import("std");
const glfw = @import("glfw");

pub fn processInput(window: glfw.Window, ctx: *nk.Context) void {
    nk.inputBegin(ctx);
    defer nk.inputEnd(ctx);

    const cursor_pos = window.getCursorPos();
    const lmb = window.getMouseButton(.left);
    const rmb = window.getMouseButton(.left);

    nk.inputMotion(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos));
    nk.inputButton(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos), nk.button_left, lmb != .release);
    nk.inputButton(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos), nk.button_right, rmb != .release);

    if (!nk.hasFocus(ctx)) return;

    var glfw_ptr = window.getUserPointer(Window.GlfwCbCtx) orelse unreachable;

    nk.inputScroll(ctx, glfw_ptr.x_scroll, glfw_ptr.y_scroll);
    glfw_ptr.x_scroll = 0;
    glfw_ptr.y_scroll = 0;
}
