pub const Quadratic = struct {
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
        const inv_2a = 0.5 / self.a;

        const l_root = (-self.b - sqrt_delta) * inv_2a;
        const r_root = (-self.b + sqrt_delta) * inv_2a;

        return switch (inv_2a < 0) {
            true => .{ r_root, l_root },
            false => .{ l_root, r_root },
        };
    }
};

pub const Line = struct {
    a: f32,
    b: f32,

    pub fn init(point: @Vector(2, f32), dir: @Vector(2, f32)) @This() {
        const div = dir[1] / dir[0];
        return .{ .a = div, .b = point[1] - div * point[0] };
    }

    pub fn value(self: @This(), x: f32) f32 {
        return @mulAdd(f32, x, self.a, self.b);
    }
};
