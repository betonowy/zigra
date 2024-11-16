const la = @import("la");

pub fn verletVelocity(T: type, velocity: T, acceleration: T, delay: f32) T {
    if (comptime la.isScalar(T)) {
        return @mulAdd(T, acceleration, delay, velocity);
    } else {
        return @mulAdd(T, acceleration, @splat(delay), velocity);
    }
}

pub fn verletPosition(T: type, position: T, velocity: T, acceleration: T, delay: f32) T {
    if (comptime la.isScalar(T)) {
        return @mulAdd(T, velocity, delay, position) + acceleration * delay * delay * 0.5;
    } else {
        return @mulAdd(T, velocity, @splat(delay), position) +
            acceleration * @as(T, @splat(delay * delay * 0.5));
    }
}

pub fn eulerVelocity(T: type, velocity: T, acceleration: T, delay: f32) T {
    if (comptime la.isScalar(T)) {
        return @mulAdd(T, acceleration, delay, velocity);
    } else {
        return @mulAdd(T, acceleration, @splat(delay), velocity);
    }
}

pub fn eulerPosition(T: type, position: T, velocity: T, delay: f32) T {
    if (comptime la.isScalar(T)) {
        return @mulAdd(T, velocity, delay, position);
    } else {
        return @mulAdd(T, velocity, @splat(delay), position);
    }
}
