const std = @import("std");
const SandSim = @import("SandSim.zig");
const utils = @import("utils");

const Result = struct {
    pos: @Vector(2, f32),
    nor: ?@Vector(2, f32),
    dir: @Vector(2, f32),
};

const CellCompareFn = fn (cell: SandSim.Cell) f32;

pub fn intersect(view: *SandSim.LandscapeView, start: @Vector(2, f32), target: @Vector(2, f32), cmp_fn: CellCompareFn) !?Result {
    var intersection_pos_opt: ?@Vector(2, f32) = null;
    var kbi = utils.KBI.init(.{ 0, 0, 0, 0 });
    var dda = utils.DDA.init(start, target);

    while (!dda.finished) : (dda.next()) {
        const pos = start + dda.dir * @as(@Vector(2, f32), @splat(if (dda.iterations > 0) dda.dist() else 0));
        kbi = utils.KBI.init(try getKernel(view, pos, cmp_fn));
        const result = kbi.getIntersection(pos - @floor(pos), dda.dir);

        switch (result) {
            .hit => |v| {
                intersection_pos_opt = v + @floor(pos);
                break;
            },
            .inside, .inside_trivial => {
                intersection_pos_opt = pos;
                break;
            },
            else => {},
        }
    }

    if (intersection_pos_opt) |pos| {
        const isect_diff = pos - start;
        const max_diff = target - start;

        if (@reduce(.Add, isect_diff * isect_diff) > @reduce(.Add, max_diff * max_diff)) {
            return noIntersection(start, dda.dir, kbi);
        }

        return .{
            .pos = pos,
            .nor = kbi.getNormal(pos - @floor(pos)),
            .dir = dda.dir,
        };
    }

    return noIntersection(start, dda.dir, kbi);
}

fn noIntersection(pos: @Vector(2, f32), dir: @Vector(2, f32), kbi: utils.KBI) !?Result {
    const nor = kbi.getNormal(pos - @floor(pos));
    return switch (kbi.isInside(pos - @floor(pos))) {
        true => .{ .pos = pos, .nor = nor, .dir = dir },
        false => null,
    };
}

const KPos = enum(usize) { ul = 0, ur = 1, bl = 2, br = 3 };

const KCoords = struct {
    minor: @Vector(2, i32),
    major: @Vector(2, i32),

    pub fn init(pos: @Vector(2, f32)) @This() {
        return .{
            .minor = @intFromFloat(@floor(pos + @Vector(2, f32){ 0, 0 })),
            .major = @intFromFloat(@floor(pos + @Vector(2, f32){ 1, 1 })),
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

fn getKernel(view: *SandSim.LandscapeView, pos: @Vector(2, f32), cmp_fn: CellCompareFn) !@Vector(4, f32) {
    const coords = KCoords.init(pos);
    var kernel: @Vector(4, f32) = undefined;

    inline for (@intFromEnum(KPos.ul)..@intFromEnum(KPos.br) + 1) |i| {
        const cell = try view.get(coords.get(@enumFromInt(i)));
        kernel[i] = cmp_fn(cell);
    }

    return kernel;
}
