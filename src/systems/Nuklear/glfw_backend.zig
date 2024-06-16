const nk = @import("nuklear");
const zigra = @import("../../zigra.zig");
const vk_types = @import("../Vulkan/types.zig");
const std = @import("std");
const glfw = @import("glfw");

pub fn processInput(window: glfw.Window, ctx: *nk.Context) void {
    nk.inputBegin(ctx);

    const cursor_pos = window.getCursorPos();
    const lmb = window.getMouseButton(.left);
    const rmb = window.getMouseButton(.left);

    nk.inputMotion(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos));
    nk.inputButton(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos), nk.button_left, lmb != .release);
    nk.inputButton(ctx, @intFromFloat(cursor_pos.xpos), @intFromFloat(cursor_pos.ypos), nk.button_right, rmb != .release);

    nk.inputEnd(ctx);
}
