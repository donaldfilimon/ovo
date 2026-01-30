//! Activation functions for the neural network. Pure functions; no allocator.
//! Derivatives are for backprop (d/dx of activation at x); sigmoid/relu/tanh for hidden,
//! sigmoid/softmax for output in classification.
const std = @import("std");

/// Sigmoid: 1 / (1 + exp(-x)). Suitable for output (binary) or hidden.
pub fn sigmoid(x: f32) f32 {
    return 1.0 / (1.0 + std.math.exp(-x));
}

/// ReLU: max(0, x). Suitable for hidden layers.
pub fn relu(x: f32) f32 {
    return @max(0.0, x);
}

/// Tanh: (exp(x) - exp(-x)) / (exp(x) + exp(-x)). Suitable for hidden or output.
pub fn tanh(x: f32) f32 {
    return std.math.tanh(x);
}

/// Leaky ReLU: x if x >= 0 else slope * x. slope typically 0.01. Suitable for hidden.
pub fn leakyRelu(x: f32, slope: f32) f32 {
    return if (x >= 0.0) x else slope * x;
}

/// Softmax over slice in-place. Caller provides buffer; suitable for output (multi-class).
pub fn softmax(buf: []f32) void {
    if (buf.len == 0) return;
    var max_val = buf[0];
    for (buf[1..]) |v| {
        if (v > max_val) max_val = v;
    }
    var sum: f32 = 0;
    for (buf, 0..) |v, i| {
        buf[i] = std.math.exp(v - max_val);
        sum += buf[i];
    }
    for (buf) |*v| v.* /= sum;
}

/// d/dx sigmoid(x) = sigmoid(x) * (1 - sigmoid(x)). For backprop, pass preactivation y: derivative is sigmoid(y)*(1-sigmoid(y)).
pub fn sigmoidDerivative(y: f32) f32 {
    const s = sigmoid(y);
    return s * (1.0 - s);
}

/// d/dx relu(x): 1 if x > 0 else 0. For backprop pass preactivation (pre-activation value).
pub fn reluDerivative(preactivation: f32) f32 {
    return if (preactivation > 0.0) 1.0 else 0.0;
}

/// d/dx tanh(x) = 1 - tanh(x)^2. For backprop pass preactivation.
pub fn tanhDerivative(preactivation: f32) f32 {
    const t = std.math.tanh(preactivation);
    return 1.0 - t * t;
}

/// Leaky ReLU derivative: 1 if x >= 0 else slope.
pub fn leakyReluDerivative(preactivation: f32, slope: f32) f32 {
    return if (preactivation >= 0.0) 1.0 else slope;
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

test "tanh known values" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tanh(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tanh(100.0), 1e-5);
}

test "leaky_relu" {
    try std.testing.expectEqual(@as(f32, -0.01), leakyRelu(-1.0, 0.01));
    try std.testing.expectEqual(@as(f32, 1.0), leakyRelu(1.0, 0.01));
}

test "softmax" {
    var buf = [_]f32{ 1.0, 2.0, 3.0 };
    softmax(&buf);
    var sum: f32 = 0;
    for (buf) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);
}

test "sigmoid derivative" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sigmoidDerivative(0.0), 1e-5);
}

test "relu derivative" {
    try std.testing.expectEqual(@as(f32, 1.0), reluDerivative(1.0));
    try std.testing.expectEqual(@as(f32, 0.0), reluDerivative(-1.0));
}
