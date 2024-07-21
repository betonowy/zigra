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
    var dda = utils.DDA.init(start, target);

    var intersection_pos_opt: ?@Vector(2, f32) = null;
    var krn_wgt: @Vector(4, f32) = undefined;

    while (!dda.finished) {
        defer _ = dda.next();

        const pos = start + dda.dir * @as(@Vector(2, f32), @splat(if (dda.iterations > 0) dda.dist() else 0));

        const krn_pos = pos - @floor(pos);
        krn_wgt = try getKernel(view, pos, cmp_fn);

        // std.debug.print("k: {d:.1}, p: {d:.3}, dp: {d:.3}, sp: {d:.3}, ", .{ krn_wgt, krn_pos, pos, start });

        if (@abs(dda.dir[0]) < @abs(dda.dir[1])) {
            const sh_pos = @shuffle(f32, krn_pos, krn_pos, [_]i32{ 1, 0 });
            const sh_dir = @shuffle(f32, dda.dir, dda.dir, [_]i32{ 1, 0 });
            const sh_krn = @shuffle(f32, krn_wgt, krn_wgt, [_]i32{ 0, 2, 1, 3 });

            if (kernelIntersection(sh_pos, sh_dir, sh_krn)) |result| {
                intersection_pos_opt = @shuffle(f32, result, result, [_]i32{ 1, 0 }) + @floor(pos);
                break;
            }

            continue;
        }

        if (kernelIntersection(krn_pos, dda.dir, krn_wgt)) |result| {
            intersection_pos_opt = result + @floor(pos);
            break;
        }
    }

    if (intersection_pos_opt) |pos| {
        const isect_diff = pos - start;
        const max_diff = target - start;

        if (@reduce(.Add, isect_diff * isect_diff) > @reduce(.Add, max_diff * max_diff)) {
            return noIntersection(view, start, dda.dir, cmp_fn);
        }

        return .{
            .pos = pos,
            .nor = kernelNormal(pos, krn_wgt),
            .dir = dda.dir,
        };
    }

    return noIntersection(view, start, dda.dir, cmp_fn);
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

fn noIntersection(view: *SandSim.LandscapeView, pos: @Vector(2, f32), dir: @Vector(2, f32), cmp_fn: CellCompareFn) !?Result {
    const krn = try getKernel(view, pos, cmp_fn);
    const nor = kernelNormal(pos, krn);
    return switch (kernelInside(pos - @floor(pos), krn)) {
        true => .{ .pos = pos, .nor = nor, .dir = dir },
        false => null,
    };
}

const kernel_threshold = 1.0 / 3.0;

fn kernelIntersection(pos: @Vector(2, f32), dir: @Vector(2, f32), krn: @Vector(4, f32)) ?@Vector(2, f32) {
    const line = LineEquation.init(pos, dir);

    const intersectionFunction = QuadraticFunction{
        .a = line.a * (krn[0] - krn[1] - krn[2] + krn[3]),
        .b = line.b * (krn[0] - krn[1] - krn[2] + krn[3]) + line.a * (krn[2] - krn[0]) + krn[1] - krn[0],
        .c = line.b * (krn[2] - krn[0]) + krn[0] - kernel_threshold,
    };

    const roots = intersectionFunction.roots() orelse return null;

    const root = switch ((dir[0] > 0 and roots[0] >= pos[0]) or (dir[0] < 0 and roots[1] > pos[0])) {
        true => roots[0],
        false => roots[1],
    };

    const hit: @Vector(2, f32) = .{ root, line.getY(root) };

    if (hit[0] < 0 or hit[0] > 1 or hit[1] < 0 or hit[1] > 1) return null;
    if (@reduce(.Add, (hit - pos) * dir) < 0) return null;

    return hit;
}

fn kernelInside(pos: @Vector(2, f32), krn: @Vector(4, f32)) bool {
    return @reduce(.Add, krn * bilinearWeights(pos)) > kernel_threshold;
}

fn kernelNormal(pos: @Vector(2, f32), krn: @Vector(4, f32)) ?@Vector(2, f32) {
    const gradient = kernelGradient(pos, krn);
    if (@reduce(.And, gradient == @Vector(2, f32){ 0, 0 })) return null;
    return gradient / @as(@Vector(2, f32), @splat(@sqrt(@reduce(.Add, gradient * gradient))));
}

fn bilinearWeights(pos: @Vector(2, f32)) @Vector(4, f32) {
    const x: @Vector(4, f32) = .{ 1 - pos[0], pos[0], 1 - pos[0], pos[0] };
    const y: @Vector(4, f32) = .{ 1 - pos[1], 1 - pos[1], pos[1], pos[1] };
    return x * y;
}

fn kernelGradient(pos: @Vector(2, f32), krn: @Vector(4, f32)) @Vector(2, f32) {
    return .{
        (1 - pos[1]) * (krn[0] - krn[1]) + pos[1] * (krn[2] - krn[3]),
        (1 - pos[0]) * (krn[0] - krn[2]) + pos[0] * (krn[1] - krn[3]),
    };
}

const QuadraticFunction = struct {
    a: f32,
    b: f32,
    c: f32,

    pub fn value(self: @This(), x: f32) f32 {
        return @mulAdd(f32, x, @mulAdd(f32, x, self.a, self.b), self.c);
    }

    pub fn roots(self: @This()) ?[2]f32 {
        const delta = self.b * self.b - 4 * self.a * self.c;
        if (delta < 0) return null;

        if (self.a == 0) {
            if (self.b == 0) return null;
            const root = -self.c / self.b;
            return .{ root, root };
        }

        const sqrt_delta = @sqrt(delta);
        const inv_2a = 0.5 * self.a;

        const l_root = (-self.b - sqrt_delta) * inv_2a;
        const r_root = (-self.b + sqrt_delta) * inv_2a;

        return switch (inv_2a < 0) {
            true => .{ r_root, l_root },
            false => .{ l_root, r_root },
        };
    }
};

const LineEquation = struct {
    a: f32,
    b: f32,

    pub fn init(point: @Vector(2, f32), dir: @Vector(2, f32)) @This() {
        const a = dir[1] / dir[0];
        return .{ .a = a, .b = @mulAdd(f32, a, -point[0], point[1]) };
    }

    pub fn getY(self: @This(), x: f32) f32 {
        return @mulAdd(f32, x, self.a, self.b);
    }
};
