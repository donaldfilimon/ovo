const std = @import("std");
const network = @import("network.zig");
const layer = @import("layer.zig");
const loss = @import("loss.zig");
const activation = @import("activation.zig");

const Network = network.Network;
const ActivationFn = network.ActivationFn;
const ActivationDerivativeFn = network.ActivationDerivativeFn;

/// Gradients for one training step. Caller allocates with allocGradients, frees with deinit.
pub const Gradients = struct {
    d_weights: []f32,
    d_biases: []f32,
    allocator: std.mem.Allocator,

    pub fn allocGradients(allocator: std.mem.Allocator, layer_sizes: []const usize) !Gradients {
        const d_weights = try allocator.alloc(f32, layer.totalWeightCount(layer_sizes));
        const d_biases = try allocator.alloc(f32, layer.totalBiasCount(layer_sizes));
        @memset(d_weights, 0);
        @memset(d_biases, 0);
        return .{ .d_weights = d_weights, .d_biases = d_biases, .allocator = allocator };
    }
    pub fn deinit(self: *Gradients) void {
        self.allocator.free(self.d_weights);
        self.allocator.free(self.d_biases);
        self.* = undefined;
    }
};

/// One SGD step: forward, MSE gradient at output, backward, update. Returns loss (MSE).
pub fn trainStepMse(
    net: *Network,
    allocator: std.mem.Allocator,
    input: []const f32,
    target: []const f32,
    lr: f32,
    act_fn: ActivationFn,
    act_derivative_fn: ActivationDerivativeFn,
) !f32 {
    const pred = try net.forward(allocator, input, act_fn);
    defer allocator.free(pred);
    const loss_val = loss.mse(pred, target);
    const output_grad = try allocator.alloc(f32, pred.len);
    defer allocator.free(output_grad);
    loss.mseGradient(pred, target, output_grad);
    var grads = try Gradients.allocGradients(allocator, net.layer_sizes);
    defer grads.deinit();
    try backward(net, allocator, input, output_grad, act_fn, act_derivative_fn, &grads);
    update(net, lr, &grads);
    return loss_val;
}

/// One minibatch SGD step: accumulate gradients over batch, average, update. Returns mean MSE.
pub fn trainStepMseBatch(
    net: *Network,
    allocator: std.mem.Allocator,
    inputs: []const f32,
    targets: []const f32,
    batch_size: usize,
    lr: f32,
    act_fn: ActivationFn,
    act_derivative_fn: ActivationDerivativeFn,
) !f32 {
    const input_size = net.layer_sizes[0];
    const output_size = net.layer_sizes[net.layer_sizes.len - 1];
    if (inputs.len != batch_size * input_size) return error.InputSizeMismatch;
    if (targets.len != batch_size * output_size) return error.TargetSizeMismatch;
    var grads = try Gradients.allocGradients(allocator, net.layer_sizes);
    defer grads.deinit();
    @memset(grads.d_weights, 0);
    @memset(grads.d_biases, 0);

    var total_loss: f32 = 0;
    for (0..batch_size) |b| {
        const in_slice = inputs[b * input_size ..][0..input_size];
        const target_slice = targets[b * output_size ..][0..output_size];
        const pred = try net.forward(allocator, in_slice, act_fn);
        defer allocator.free(pred);
        total_loss += loss.mse(pred, target_slice);
        const output_grad = try allocator.alloc(f32, pred.len);
        defer allocator.free(output_grad);
        loss.mseGradient(pred, target_slice, output_grad);
        try backward(net, allocator, in_slice, output_grad, act_fn, act_derivative_fn, &grads);
    }

    const inv = 1.0 / @as(f32, @floatFromInt(batch_size));
    for (grads.d_weights) |*g| g.* *= inv;
    for (grads.d_biases) |*g| g.* *= inv;
    update(net, lr, &grads);
    return total_loss * inv;
}

fn backward(
    net: *const Network,
    allocator: std.mem.Allocator,
    input: []const f32,
    output_grad: []const f32,
    act_fn: ActivationFn,
    act_derivative_fn: ActivationDerivativeFn,
    grads: *Gradients,
) !void {
    const num_layers = net.layer_sizes.len - 1;
    var total_act: usize = 0;
    for (net.layer_sizes) |s| total_act += s;
    const total_preact = layer.totalBiasCount(net.layer_sizes);
    const preacts = try allocator.alloc(f32, total_preact);
    defer allocator.free(preacts);
    const acts = try allocator.alloc(f32, total_act);
    defer allocator.free(acts);
    @memcpy(acts[0..input.len], input);
    var preact_offset: usize = 0;
    var act_offset: usize = input.len;
    for (0..num_layers) |l| {
        const in_size = net.layer_sizes[l];
        const out_size = net.layer_sizes[l + 1];
        const w_start = layer.startWeight(net.layer_sizes, l);
        const b_start = layer.startBias(net.layer_sizes, l);
        const W = net.weights[w_start..][0..(out_size * in_size)];
        const b = net.biases[b_start..][0..out_size];
        const in_buf = acts[act_offset - in_size ..][0..in_size];
        const out_buf = acts[act_offset..][0..out_size];
        for (0..out_size) |j| {
            var sum: f32 = b[j];
            for (0..in_size) |i| sum += in_buf[i] * W[j * in_size + i];
            preacts[preact_offset + j] = sum;
            out_buf[j] = act_fn(sum);
        }
        preact_offset += out_size;
        act_offset += out_size;
    }
    var max_size: usize = 0;
    for (net.layer_sizes) |s| {
        if (s > max_size) max_size = s;
    }
    var grad_cur = try allocator.alloc(f32, max_size);
    defer allocator.free(grad_cur);
    var grad_prev = try allocator.alloc(f32, max_size);
    defer allocator.free(grad_prev);
    @memcpy(grad_cur[0..output_grad.len], output_grad);
    preact_offset = total_preact;
    var act_input_start: usize = 0;
    for (0..num_layers - 1) |l| act_input_start += net.layer_sizes[l];
    var layer_idx = num_layers;
    while (layer_idx > 0) {
        layer_idx -= 1;
        const in_size = net.layer_sizes[layer_idx];
        const out_size = net.layer_sizes[layer_idx + 1];
        preact_offset -= out_size;
        const w_start = layer.startWeight(net.layer_sizes, layer_idx);
        const b_start = layer.startBias(net.layer_sizes, layer_idx);
        const W = net.weights[w_start..][0..(out_size * in_size)];
        const d_W = grads.d_weights[w_start..][0..(out_size * in_size)];
        const d_b = grads.d_biases[b_start..][0..out_size];
        const preact = preacts[preact_offset..][0..out_size];
        const input_act: []const f32 = if (layer_idx == 0) input else acts[act_input_start..][0..in_size];
        if (layer_idx > 0) {
            for (0..in_size) |i| {
                var s: f32 = 0;
                for (0..out_size) |j| {
                    s += W[j * in_size + i] * grad_cur[j] * act_derivative_fn(preact[j]);
                }
                grad_prev[i] = s;
            }
        }
        for (0..out_size) |j| {
            const d_preact = grad_cur[j] * act_derivative_fn(preact[j]);
            d_b[j] += d_preact;
            for (0..in_size) |i| d_W[j * in_size + i] += d_preact * input_act[i];
        }
        if (layer_idx > 0) {
            act_input_start -= net.layer_sizes[layer_idx - 1];
            @memcpy(grad_cur[0..in_size], grad_prev[0..in_size]);
        }
    }
}

fn update(net: *Network, lr: f32, grads: *const Gradients) void {
    for (net.weights, grads.d_weights) |*w, d| w.* -= lr * d;
    for (net.biases, grads.d_biases) |*b, d| b.* -= lr * d;
}

test "trainStepMse decreases loss" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    const input = [_]f32{ 0.5, -0.3 };
    const target = [_]f32{0.8};
    const loss0 = try trainStepMse(&net, gpa, &input, &target, 0.1, activation.sigmoid, activation.sigmoidDerivative);
    const loss1 = try trainStepMse(&net, gpa, &input, &target, 0.1, activation.sigmoid, activation.sigmoidDerivative);
    try std.testing.expect(loss1 <= loss0 + 0.01);
}

test "trainStepMseBatch runs" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(123);
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    const inputs = [_]f32{ 0.5, -0.3, 0.2, 0.9 };
    const targets = [_]f32{ 0.8, 0.1 };
    const loss_val = try trainStepMseBatch(
        &net,
        gpa,
        &inputs,
        &targets,
        2,
        0.1,
        activation.sigmoid,
        activation.sigmoidDerivative,
    );
    try std.testing.expect(!std.math.isNan(loss_val));
}

test "gradient check (single weight)" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(2024);
    const sizes = [_]usize{ 2, 2, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    const input = [_]f32{ 0.4, -0.2 };
    const target = [_]f32{ 0.7 };

    const pred = try net.forward(gpa, &input, activation.sigmoid);
    defer gpa.free(pred);
    const output_grad = try gpa.alloc(f32, pred.len);
    defer gpa.free(output_grad);
    loss.mseGradient(pred, &target, output_grad);
    var grads = try Gradients.allocGradients(gpa, &sizes);
    defer grads.deinit();
    try backward(&net, gpa, &input, output_grad, activation.sigmoid, activation.sigmoidDerivative, &grads);
    const analytic = grads.d_weights[0];

    const eps: f32 = 1e-3;
    const w0 = net.weights[0];
    net.weights[0] = w0 + eps;
    const pred_plus = try net.forward(gpa, &input, activation.sigmoid);
    defer gpa.free(pred_plus);
    const loss_plus = loss.mse(pred_plus, &target);

    net.weights[0] = w0 - eps;
    const pred_minus = try net.forward(gpa, &input, activation.sigmoid);
    defer gpa.free(pred_minus);
    const loss_minus = loss.mse(pred_minus, &target);
    net.weights[0] = w0;

    const numerical = (loss_plus - loss_minus) / (2.0 * eps);
    try std.testing.expectApproxEqAbs(analytic, numerical, 1e-2);
}
