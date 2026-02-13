const std = @import("std");

pub fn relu(value: f32) f32 {
    if (value > 0.0) return value;
    return 0.0;
}

pub fn sigmoid(value: f32) f32 {
    return 1.0 / (1.0 + std.math.exp(-value));
}
