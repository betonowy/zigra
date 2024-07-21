const std = @import("std");
const SandSim = @import("SandSim.zig");

view: SandSim.LandscapeView,

pos: @Vector(2, f32),
pos_start: @Vector(2, f32),
pos_dirty: bool = true,

kernel: @Vector(4, f32),

pub fn init(view: SandSim.LandscapeView, pos: @Vector(2, f32)) @This() {
    return .{ .view = view, .pos_start = pos, .pos = pos };
}

const KPos = enum(usize) { ul = 0, ur = 1, bl = 2, br = 3 };

const KCoords = struct {
    minor: @Vector(2, i32),
    major: @Vector(2, i32),

    pub fn init(pos: @Vector(2, f32)) @This() {
        return .{
            .minor = @floor(pos + @Vector(2, f32){ 0, 0 }),
            .major = @floor(pos + @Vector(2, f32){ 1, 1 }),
        };
    }

    pub fn get(self: @This(), pos: KPos) @Vector(2, i32) {
        return switch (pos) {
            .ul => .{ self.minor[0], self.minor[1] },
            .ur => .{ self.major[0], self.minor[1] },
            .bl => .{ self.minor[0], self.major[1] },
            .br => .{ self.major[0], self.major[1] },
        };
    }
};

fn updateKernel(self: *@This()) !void {
    const coords = KCoords.init(self.pos);
    inline for (KPos.ul..KPos.br + 1) |i| {
        self.kernel[i] = try self.view.get(coords.get(@enumFromInt(i)));
    }
}

pub fn march(self: *@This()) !void {
    _ = self; // autofix

}
