const std = @import("std");
const SandSim = @import("SandSim.zig");
const utils = @import("utils");
const la = @import("la");

const Result = struct {
    pos: @Vector(2, f32),
    nor: ?@Vector(2, f32),
    dir: @Vector(2, f32),
    no_intersection: bool = false,
};

const CellCompareFn = fn (cell: SandSim.Cell) f32;

pub fn intersect(view: *SandSim.LandscapeView, start: @Vector(2, f32), target: @Vector(2, f32), cmp_fn: CellCompareFn) !?Result {
    var intersection_pos_opt: ?@Vector(2, f32) = null;
    var kbi = try getKernel(view, start, cmp_fn);

    if (@reduce(.Or, start != target)) {
        var dda = utils.DDA.init(start, target);

        while (!dda.finished) : (dda.next()) {
            const pos = start + dda.dir * @as(@Vector(2, f32), @splat(if (dda.iterations > 0) dda.dist() else 0));
            const kpos = pos - @as(@Vector(2, f32), @floatFromInt(dda.current_cell));

            kbi = try getKernelI(view, dda.current_cell, cmp_fn);

            const result = utils.KBI.intersection(kbi, kpos, dda.dir);

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
                .nor = utils.KBI.normal(kbi, pos - @floor(pos)),
                .dir = dda.dir,
            };
        }
    }

    return noIntersection(start, la.normalize(target - start), kbi);
}

fn noIntersection(pos: @Vector(2, f32), dir: @Vector(2, f32), kbi: @Vector(4, f32)) !?Result {
    const nor = utils.KBI.normal(kbi, pos - @floor(pos));
    return switch (utils.KBI.isInside(kbi, pos - @floor(pos))) {
        true => .{ .pos = pos, .nor = nor, .dir = dir, .no_intersection = true },
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

fn getKernelI(view: *SandSim.LandscapeView, pos: @Vector(2, i32), cmp_fn: CellCompareFn) !@Vector(4, f32) {
    const coords = KCoords{
        .minor = pos,
        .major = pos + @Vector(2, i32){ 1, 1 },
    };
    var kernel: @Vector(4, f32) = undefined;

    inline for (@intFromEnum(KPos.ul)..@intFromEnum(KPos.br) + 1) |i| {
        const cell = try view.get(coords.get(@enumFromInt(i)));
        kernel[i] = cmp_fn(cell);
    }

    return kernel;
}
