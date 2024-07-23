const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");

const nk = @import("nuklear");
const nk_vk = @import("Nuklear/vk_backend.zig");
const nk_glfw = @import("Nuklear/glfw_backend.zig");

const nk_max_mem = 1 * 1024 * 1024;
const nk_mem_alignment = 16;

allocator: std.mem.Allocator,
nk_mem: ?[]u8 = null,
nk: nk.Context = undefined,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .allocator = allocator };
}

pub fn systemInit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
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

    try nk.initFixed(&self.nk, self.nk_mem.?, &user_font);
}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn systemDeinit(self: *@This(), _: *lifetime.ContextBase) anyerror!void {
    nk.deinit(&self.nk);
    if (self.nk_mem) |mem| self.allocator.free(mem);
}

pub fn inputProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    nk_glfw.processInput(ctx.systems.window.window, &self.nk);
}

pub fn process(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn render(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    try nk.forEachDrawCommand(&self.nk, *zigra.Context, ctx, nk_vk.renderCallback);
    nk.clear(&self.nk);
}
