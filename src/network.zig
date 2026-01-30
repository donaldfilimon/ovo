//! Feedforward network: layer_sizes, contiguous weights/biases, forward pass.
const std = @import("std");
const layer = @import("layer.zig");
const activation = @import("activation.zig");

/// Activation function type for the forward pass.
pub const ActivationFn = *const fn (f32) f32;

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

    pub fn deinit(self: *Network) void {
        self.allocator.free(self.layer_sizes);
        self.allocator.free(self.weights);
        self.allocator.free(self.biases);
        self.* = undefined;
    }

    /// Forward pass. Uses `act_fn` for all layers. Caller owns returned slice.
    pub fn forward(
        self: *const Network,
        allocator: std.mem.Allocator,
        input: []const f32,
        act_fn: ActivationFn,
    ) ![]f32 {
        if (input.len != self.layer_sizes[0]) return error.InputSizeMismatch;
        const num_layers = self.layer_sizes.len - 1;
        const output_size = self.layer_sizes[self.layer_sizes.len - 1];
        var max_size: usize = 0;
        for (self.layer_sizes) |s| {
            if (s > max_size) max_size = s;
        }
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
};

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

test "network forward input size mismatch" {
    const gpa = std.testing.allocator;
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.init(gpa, &sizes);
    defer net.deinit();
    const input = [_]f32{ 0.5 };
    const result = net.forward(gpa, &input, activation.sigmoid);
    try std.testing.expectError(error.InputSizeMismatch, result);
}
