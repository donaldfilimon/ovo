//! Loss functions for training. Return scalar; backprop needs gradient of loss w.r.t. pred.
const std = @import("std");

/// Mean squared error: (1/n) * sum((pred[i] - target[i])^2). For regression.
pub fn mse(pred: []const f32, target: []const f32) f32 {
    std.debug.assert(pred.len == target.len and pred.len > 0);
    var sum: f32 = 0;
    for (pred, target) |p, t| {
        const d = p - t;
        sum += d * d;
    }
    return sum / @as(f32, @floatFromInt(pred.len));
}

/// Gradient of MSE w.r.t. pred: d_loss/d_pred[i] = 2*(pred[i]-target[i])/n. Writes into grad_out; caller owns.
pub fn mseGradient(pred: []const f32, target: []const f32, grad_out: []f32) void {
    std.debug.assert(pred.len == target.len and pred.len == grad_out.len);
    const n = @as(f32, @floatFromInt(pred.len));
    for (pred, target, grad_out) |p, t, *g| {
        g.* = 2.0 * (p - t) / n;
    }
}

/// Mean absolute error: (1/n) * sum(|pred[i] - target[i]|). More robust to outliers.
pub fn mae(pred: []const f32, target: []const f32) f32 {
    std.debug.assert(pred.len == target.len and pred.len > 0);
    var sum: f32 = 0;
    for (pred, target) |p, t| {
        sum += @abs(p - t);
    }
    return sum / @as(f32, @floatFromInt(pred.len));
}

/// Gradient of MAE w.r.t. pred: sign(pred[i] - target[i]) / n.
pub fn maeGradient(pred: []const f32, target: []const f32, grad_out: []f32) void {
    std.debug.assert(pred.len == target.len and pred.len == grad_out.len);
    const n = @as(f32, @floatFromInt(pred.len));
    for (pred, target, grad_out) |p, t, *g| {
        const diff = p - t;
        g.* = if (diff > 0) 1.0 / n else if (diff < 0) -1.0 / n else 0.0;
    }
}

/// Huber loss: quadratic for small errors, linear for large. delta controls transition.
pub fn huber(pred: []const f32, target: []const f32, delta: f32) f32 {
    std.debug.assert(pred.len == target.len and pred.len > 0);
    var sum: f32 = 0;
    for (pred, target) |p, t| {
        const diff = @abs(p - t);
        if (diff <= delta) {
            sum += 0.5 * diff * diff;
        } else {
            sum += delta * (diff - 0.5 * delta);
        }
    }
    return sum / @as(f32, @floatFromInt(pred.len));
}

/// Binary cross-entropy: -target*log(pred) - (1-target)*log(1-pred). pred is single probability (sigmoid output).
pub fn binaryCrossEntropy(pred: f32, target: f32) f32 {
    const eps: f32 = 1e-7;
    const p = @max(eps, @min(1.0 - eps, pred));
    return -(target * @log(p) + (1.0 - target) * @log(1.0 - p));
}

/// Gradient of binary CE w.r.t. pred: (pred - target) / (pred*(1-pred)); for sigmoid output simplifies to pred - target.
pub fn binaryCrossEntropyGradient(pred: f32, target: f32) f32 {
    return pred - target;
}

/// Binary cross-entropy over arrays.
pub fn binaryCrossEntropyBatch(pred: []const f32, target: []const f32) f32 {
    std.debug.assert(pred.len == target.len and pred.len > 0);
    var sum: f32 = 0;
    for (pred, target) |p, t| {
        sum += binaryCrossEntropy(p, t);
    }
    return sum / @as(f32, @floatFromInt(pred.len));
}

/// Cross-entropy over softmax logits: -sum(target[i]*log(softmax(pred)[i])). pred = logits, target = one-hot or probs.
/// Returns scalar loss. For one-hot target pass index of class and we compute -log(softmax(pred)[target_class]).
pub fn crossEntropyFromLogits(pred: []const f32, target_class: usize) f32 {
    std.debug.assert(target_class < pred.len);
    var max_val = pred[0];
    for (pred[1..]) |v| {
        if (v > max_val) max_val = v;
    }
    var sum_exp: f32 = 0;
    for (pred) |v| {
        sum_exp += std.math.exp(v - max_val);
    }
    const log_sum_exp = max_val + @log(sum_exp);
    return log_sum_exp - pred[target_class];
}

/// Gradient of cross-entropy w.r.t. logits: softmax(pred) - one_hot(target). Writes into grad_out.
pub fn crossEntropyGradientFromLogits(pred: []const f32, target_class: usize, grad_out: []f32) void {
    std.debug.assert(pred.len == grad_out.len and target_class < pred.len);
    var max_val = pred[0];
    for (pred[1..]) |v| {
        if (v > max_val) max_val = v;
    }
    var sum_exp: f32 = 0;
    for (pred) |v| {
        sum_exp += std.math.exp(v - max_val);
    }
    for (pred, grad_out, 0..) |v, *g, i| {
        g.* = std.math.exp(v - max_val) / sum_exp;
        if (i == target_class) g.* -= 1.0;
    }
}

/// Focal loss: (1-pt)^gamma * CE(pt). Helps with class imbalance.
pub fn focalLoss(pred: f32, target: f32, gamma: f32) f32 {
    const eps: f32 = 1e-7;
    const p = @max(eps, @min(1.0 - eps, pred));
    const pt = if (target > 0.5) p else 1.0 - p;
    const ce = binaryCrossEntropy(pred, target);
    return std.math.pow(f32, 1.0 - pt, gamma) * ce;
}

test "mse" {
    const p = [_]f32{ 1.0, 2.0, 3.0 };
    const t = [_]f32{ 1.0, 2.0, 4.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), mse(&p, &t), 1e-5);
}

test "mse gradient" {
    var grad: [3]f32 = undefined;
    mseGradient(&[_]f32{ 1.0, 2.0, 3.0 }, &[_]f32{ 1.0, 2.0, 4.0 }, &grad);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), grad[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0 / 3.0), grad[2], 1e-5);
}

test "binary cross entropy" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), binaryCrossEntropy(1.0, 1.0), 1e-5);
}

test "cross entropy from logits" {
    const logits = [_]f32{ 0.5, 2.0, 0.1 };
    const loss_val = crossEntropyFromLogits(&logits, 1);
    try std.testing.expect(loss_val >= 0.0);
}

test "mae" {
    const p = [_]f32{ 1.0, 2.0, 3.0 };
    const t = [_]f32{ 1.0, 2.0, 5.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), mae(&p, &t), 1e-5);
}

test "huber loss" {
    const p = [_]f32{ 1.0, 2.0, 3.0 };
    const t = [_]f32{ 1.0, 2.0, 4.0 };
    const loss_val = huber(&p, &t, 1.0);
    try std.testing.expect(loss_val >= 0.0);
}
