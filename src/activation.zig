//! Activation functions for the neural network. Pure functions; no allocator.
const std = @import("std");

/// Sigmoid: 1 / (1 + exp(-x))
pub fn sigmoid(x: f32) f32 {
    return 1.0 / (1.0 + std.math.exp(-x));
}

/// ReLU: max(0, x)
pub fn relu(x: f32) f32 {
    return @max(0.0, x);
}

test "sigmoid known values" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sigmoid(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7310586), sigmoid(1.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2689414), sigmoid(-1.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sigmoid(-100.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sigmoid(100.0), 1e-6);
}

test "relu known values" {
    try std.testing.expectEqual(@as(f32, 0.0), relu(-1.0));
    try std.testing.expectEqual(@as(f32, 0.0), relu(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), relu(1.0));
    try std.testing.expectEqual(@as(f32, 5.5), relu(5.5));
}
