//! Feedforward network: layer_sizes, contiguous weights/biases, forward pass, training.
const std = @import("std");
const layer = @import("layer.zig");
const activation = @import("activation.zig");
const loss = @import("loss.zig");

/// Activation function type for the forward pass.
pub const ActivationFn = *const fn (f32) f32;
/// Derivative for backprop: d/dx of activation at preactivation x.
pub const ActivationDerivativeFn = *const fn (f32) f32;

const ActSpec = union(enum) {
    single: ActivationFn,
    per_layer: []const ActivationFn,
};

/// Network owns layer_sizes, weights, and biases. Use init/deinit for lifecycle.
pub const Network = struct {
    layer_sizes: []const usize,
    weights: []f32,
    biases: []f32,
    allocator: std.mem.Allocator,

    /// Caller keeps layer_sizes alive or passes a slice the network will duplicate.
    /// Weights and biases are zero-initialized.
    pub fn init(allocator: std.mem.Allocator, layer_sizes: []const usize) !Network {
        if (layer_sizes.len < 2) return error.InvalidLayerSizes;
        const sizes = try std.mem.Allocator.dupe(allocator, usize, layer_sizes);
        errdefer allocator.free(sizes);
        const total_w = layer.totalWeightCount(layer_sizes);
        const total_b = layer.totalBiasCount(layer_sizes);
        const weights = try allocator.alloc(f32, total_w);
        errdefer allocator.free(weights);
        @memset(weights, 0);
        const biases = try allocator.alloc(f32, total_b);
        errdefer allocator.free(biases);
        @memset(biases, 0);
        return .{
            .layer_sizes = sizes,
            .weights = weights,
            .biases = biases,
            .allocator = allocator,
        };
    }

    /// Like init but weights are Xavier (scale 1/sqrt(in_size)), biases zero. Good for sigmoid/tanh.
    pub fn initXavier(allocator: std.mem.Allocator, layer_sizes: []const usize, prng: std.Random) !Network {
        var net = try init(allocator, layer_sizes);
        for (0..layer_sizes.len - 1) |l| {
            const in_size = layer_sizes[l];
            const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(in_size)));
            const w_start = layer.startWeight(layer_sizes, l);
            const w_count = layer.weightCount(layer_sizes, l);
            for (net.weights[w_start..][0..w_count]) |*w| {
                w.* = (prng.float(f32) * 2.0 - 1.0) * scale;
            }
        }
        return net;
    }

    /// Like init but weights are He (scale sqrt(2/in_size)), biases zero. Good for ReLU.
    pub fn initHe(allocator: std.mem.Allocator, layer_sizes: []const usize, prng: std.Random) !Network {
        var net = try init(allocator, layer_sizes);
        for (0..layer_sizes.len - 1) |l| {
            const in_size = layer_sizes[l];
            const scale = @sqrt(2.0 / @as(f32, @floatFromInt(in_size)));
            const w_start = layer.startWeight(layer_sizes, l);
            const w_count = layer.weightCount(layer_sizes, l);
            for (net.weights[w_start..][0..w_count]) |*w| {
                w.* = (prng.float(f32) * 2.0 - 1.0) * scale;
            }
        }
        return net;
    }

    pub fn deinit(self: *Network) void {
        self.allocator.free(self.layer_sizes);
        self.allocator.free(self.weights);
        self.allocator.free(self.biases);
        self.* = undefined;
    }

    fn forwardInternal(
        self: *const Network,
        allocator: std.mem.Allocator,
        input: []const f32,
        act_spec: ActSpec,
    ) ![]f32 {
        if (input.len != self.layer_sizes[0]) return error.InputSizeMismatch;
        const num_layers = self.layer_sizes.len - 1;
        const output_size = self.layer_sizes[self.layer_sizes.len - 1];
        const max_size = layer.maxLayerSize(self.layer_sizes);
        const scratch_a = try allocator.alloc(f32, max_size);
        defer allocator.free(scratch_a);
        const scratch_b = try allocator.alloc(f32, max_size);
        defer allocator.free(scratch_b);
        @memcpy(scratch_a[0..input.len], input);

        const output = try allocator.alloc(f32, output_size);
        errdefer allocator.free(output);

        var in_buf = scratch_a[0..input.len];
        var use_a = true;
        for (0..num_layers) |l| {
            const in_size = self.layer_sizes[l];
            const out_size = self.layer_sizes[l + 1];
            const w_start = layer.startWeight(self.layer_sizes, l);
            const b_start = layer.startBias(self.layer_sizes, l);
            const W = self.weights[w_start..][0..(out_size * in_size)];
            const b = self.biases[b_start..][0..out_size];

            const is_last = (l == num_layers - 1);
            const out_buf: []f32 = if (is_last)
                output
            else if (use_a)
                scratch_b[0..out_size]
            else
                scratch_a[0..out_size];

            const act_fn = switch (act_spec) {
                .single => |fn_single| fn_single,
                .per_layer => |fns| fns[l],
            };
            for (0..out_size) |j| {
                var sum: f32 = b[j];
                for (0..in_size) |i| {
                    sum += in_buf[i] * W[j * in_size + i];
                }
                out_buf[j] = act_fn(sum);
            }

            if (!is_last) {
                in_buf = out_buf;
                use_a = !use_a;
            }
        }
        return output;
    }

    /// Forward pass. Uses `act_fn` for all layers. Caller owns returned slice.
    pub fn forward(
        self: *const Network,
        allocator: std.mem.Allocator,
        input: []const f32,
        act_fn: ActivationFn,
    ) ![]f32 {
        return self.forwardInternal(allocator, input, .{ .single = act_fn });
    }

    /// Forward pass with per-layer activations. act_fns.len must equal num_layers.
    pub fn forwardWithActivations(
        self: *const Network,
        allocator: std.mem.Allocator,
        input: []const f32,
        act_fns: []const ActivationFn,
    ) ![]f32 {
        const num_layers = self.layer_sizes.len - 1;
        if (act_fns.len != num_layers) return error.ActivationCountMismatch;
        return self.forwardInternal(allocator, input, .{ .per_layer = act_fns });
    }

    /// Forward pass using SIMD in the inner dot-product (4-wide). Caller owns returned slice.
    pub fn forwardSimd(
        self: *const Network,
        allocator: std.mem.Allocator,
        input: []const f32,
        act_fn: ActivationFn,
    ) ![]f32 {
        if (input.len != self.layer_sizes[0]) return error.InputSizeMismatch;
        const num_layers = self.layer_sizes.len - 1;
        const output_size = self.layer_sizes[self.layer_sizes.len - 1];
        const max_size = layer.maxLayerSize(self.layer_sizes);
        const scratch_a = try allocator.alloc(f32, max_size);
        defer allocator.free(scratch_a);
        const scratch_b = try allocator.alloc(f32, max_size);
        defer allocator.free(scratch_b);
        @memcpy(scratch_a[0..input.len], input);

        const output = try allocator.alloc(f32, output_size);
        errdefer allocator.free(output);

        const Vec4 = @Vector(4, f32);
        var in_buf = scratch_a[0..input.len];
        var use_a = true;
        for (0..num_layers) |l| {
            const in_size = self.layer_sizes[l];
            const out_size = self.layer_sizes[l + 1];
            const w_start = layer.startWeight(self.layer_sizes, l);
            const b_start = layer.startBias(self.layer_sizes, l);
            const W = self.weights[w_start..][0..(out_size * in_size)];
            const b = self.biases[b_start..][0..out_size];

            const is_last = (l == num_layers - 1);
            const out_buf: []f32 = if (is_last)
                output
            else if (use_a)
                scratch_b[0..out_size]
            else
                scratch_a[0..out_size];

            for (0..out_size) |j| {
                var sum: f32 = b[j];
                var i: usize = 0;
                const row = W[j * in_size ..][0..in_size];
                while (i + 4 <= in_size) : (i += 4) {
                    const w_vec: Vec4 = .{ row[i], row[i + 1], row[i + 2], row[i + 3] };
                    const in_vec: Vec4 = .{ in_buf[i], in_buf[i + 1], in_buf[i + 2], in_buf[i + 3] };
                    sum += @reduce(.Add, w_vec * in_vec);
                }
                while (i < in_size) : (i += 1) {
                    sum += in_buf[i] * row[i];
                }
                out_buf[j] = act_fn(sum);
            }

            if (!is_last) {
                in_buf = out_buf;
                use_a = !use_a;
            }
        }
        return output;
    }

    /// Batch forward: inputs flat [batch_size * input_size], returns flat [batch_size * output_size]. Caller owns.
    pub fn forwardBatch(
        self: *const Network,
        allocator: std.mem.Allocator,
        inputs: []const f32,
        batch_size: usize,
        act_fn: ActivationFn,
    ) ![]f32 {
        const input_size = self.layer_sizes[0];
        const output_size = self.layer_sizes[self.layer_sizes.len - 1];
        if (inputs.len != batch_size * input_size) return error.InputSizeMismatch;
        const output = try allocator.alloc(f32, batch_size * output_size);
        errdefer allocator.free(output);
        var i: usize = 0;
        while (i < batch_size) : (i += 1) {
            const in_slice = inputs[i * input_size ..][0..input_size];
            const out_slice = try self.forward(allocator, in_slice, act_fn);
            defer allocator.free(out_slice);
            @memcpy(output[i * output_size ..][0..output_size], out_slice);
        }
        return output;
    }

    /// Save network to writer: num_layers (u32), layer_sizes, weights, biases.
    pub fn save(self: *const Network, writer: anytype) !void {
        try writer.writeAll("OVO1");
        try writer.writeInt(u32, 1, .little);
        try writer.writeInt(u32, @intCast(self.layer_sizes.len), .little);
        for (self.layer_sizes) |s| try writer.writeInt(u32, @intCast(s), .little);
        for (self.weights) |w| try writer.writeAll(std.mem.asBytes(&w));
        for (self.biases) |b| try writer.writeAll(std.mem.asBytes(&b));
    }

    /// Load network from reader. Caller owns returned network; call deinit.
    pub fn load(allocator: std.mem.Allocator, reader: anytype) !Network {
        var magic: [4]u8 = undefined;
        const n = try reader.readAll(&magic);
        if (n != magic.len or !std.mem.eql(u8, &magic, "OVO1")) return error.InvalidFormat;
        const version = try reader.readInt(u32, .little);
        if (version != 1) return error.UnsupportedVersion;
        const num_layers = try reader.readInt(u32, .little);
        if (num_layers < 2) return error.InvalidLayerSizes;
        const sizes = try allocator.alloc(usize, num_layers);
        errdefer allocator.free(sizes);
        for (sizes) |*s| s.* = try reader.readInt(u32, .little);
        const total_w = layer.totalWeightCount(sizes);
        const total_b = layer.totalBiasCount(sizes);
        const weights = try allocator.alloc(f32, total_w);
        errdefer allocator.free(weights);
        for (weights) |*w| _ = try reader.readAll(std.mem.asBytes(w));
        const biases = try allocator.alloc(f32, total_b);
        errdefer allocator.free(biases);
        for (biases) |*b| _ = try reader.readAll(std.mem.asBytes(b));
        return .{
            .layer_sizes = sizes,
            .weights = weights,
            .biases = biases,
            .allocator = allocator,
        };
    }
};

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
    const max_size = layer.maxLayerSize(net.layer_sizes);
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

test "network init and deinit" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.init(gpa, &sizes);
    defer net.deinit();
    try std.testing.expectEqual(@as(usize, 3), net.layer_sizes.len);
    try std.testing.expectEqual(@as(usize, 2 * 4 + 4 * 1), net.weights.len);
    try std.testing.expectEqual(@as(usize, 4 + 1), net.biases.len);
}

test "network forward" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.init(gpa, &sizes);
    defer net.deinit();
    const input = [_]f32{ 0.5, -0.3 };
    const out = try net.forward(gpa, &input, activation.sigmoid);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0] >= 0.0 and out[0] <= 1.0);
}

test "network forwardWithActivations" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var prng = std.Random.DefaultPrng.init(7);
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    const input = [_]f32{ 0.25, -0.1 };
    const act_fns = [_]ActivationFn{ activation.relu, activation.sigmoid };
    const out = try net.forwardWithActivations(gpa, &input, &act_fns);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0] >= 0.0 and out[0] <= 1.0);
}

test "network forwardSimd matches forward" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var prng = std.Random.DefaultPrng.init(9);
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    const input = [_]f32{ 0.12, -0.7 };
    const out_scalar = try net.forward(gpa, &input, activation.sigmoid);
    defer gpa.free(out_scalar);
    const out_simd = try net.forwardSimd(gpa, &input, activation.sigmoid);
    defer gpa.free(out_simd);
    try std.testing.expectApproxEqAbs(out_scalar[0], out_simd[0], 1e-5);
}

test "network forward input size mismatch" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.init(gpa, &sizes);
    defer net.deinit();
    const input = [_]f32{0.5};
    const result = net.forward(gpa, &input, activation.sigmoid);
    try std.testing.expectError(error.InputSizeMismatch, result);
}

test "network initXavier" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    try std.testing.expect(net.weights[0] != 0.0);
}

test "network save and load" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.init(gpa, &sizes);
    defer net.deinit();
    net.weights[0] = 0.5;
    var buf: std.ArrayList(u8) = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    try net.save(buf.writer());
    var loaded = try Network.load(gpa, buf.reader());
    defer loaded.deinit();
    try std.testing.expectEqual(net.layer_sizes.len, loaded.layer_sizes.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), loaded.weights[0], 1e-6);
}

test "trainStepMse decreases loss" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();
    const input = [_]f32{ 0.5, -0.3 };
    const target = [_]f32{0.8};
    const loss0 = try trainStepMse(net, gpa, &input, &target, 0.1, activation.sigmoid, activation.sigmoidDerivative);
    const loss1 = try trainStepMse(net, gpa, &input, &target, 0.1, activation.sigmoid, activation.sigmoidDerivative);
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
        net,
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
    const target = [_]f32{0.7};

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
