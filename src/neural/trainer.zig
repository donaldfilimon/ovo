//! Training utilities for neural networks.
//! Provides high-level training loops and optimization helpers.
const std = @import("std");
const network = @import("network.zig");
const layer = @import("layer.zig");
const loss = @import("loss.zig");
const activation = @import("activation.zig");

const Network = network.Network;
const Gradients = network.Gradients;
const ActivationFn = network.ActivationFn;
const ActivationDerivativeFn = network.ActivationDerivativeFn;

/// Training configuration.
pub const TrainingConfig = struct {
    /// Learning rate.
    learning_rate: f32 = 0.01,
    /// Number of epochs.
    epochs: usize = 100,
    /// Batch size (0 = full batch).
    batch_size: usize = 32,
    /// Print progress every N epochs (0 = never).
    print_every: usize = 10,
    /// Early stopping patience (0 = disabled).
    patience: usize = 0,
    /// Minimum improvement for early stopping.
    min_delta: f32 = 1e-4,
    /// Activation function.
    activation_fn: ActivationFn = activation.sigmoid,
    /// Activation derivative.
    activation_derivative: ActivationDerivativeFn = activation.sigmoidDerivative,
};

/// Training result.
pub const TrainingResult = struct {
    /// Final loss.
    final_loss: f32,
    /// Number of epochs trained.
    epochs_trained: usize,
    /// Loss history (if recorded).
    loss_history: ?[]f32,
    /// Whether early stopping triggered.
    early_stopped: bool,

    pub fn deinit(self: *TrainingResult, allocator: std.mem.Allocator) void {
        if (self.loss_history) |history| {
            allocator.free(history);
        }
        self.* = undefined;
    }
};

/// Train network with full batch gradient descent.
pub fn train(
    net: *Network,
    allocator: std.mem.Allocator,
    inputs: []const f32,
    targets: []const f32,
    config: TrainingConfig,
) !TrainingResult {
    const input_size = net.layer_sizes[0];
    const output_size = net.layer_sizes[net.layer_sizes.len - 1];
    const num_samples = inputs.len / input_size;

    if (inputs.len != num_samples * input_size) return error.InputSizeMismatch;
    if (targets.len != num_samples * output_size) return error.TargetSizeMismatch;

    var loss_history = try allocator.alloc(f32, config.epochs);
    errdefer allocator.free(loss_history);

    var best_loss: f32 = std.math.floatMax(f32);
    var patience_counter: usize = 0;
    var epochs_trained: usize = 0;
    var early_stopped = false;

    for (0..config.epochs) |epoch| {
        const loss_val = if (config.batch_size == 0 or config.batch_size >= num_samples)
            try network.trainStepMseBatch(
                net,
                allocator,
                inputs,
                targets,
                num_samples,
                config.learning_rate,
                config.activation_fn,
                config.activation_derivative,
            )
        else
            try trainEpochMiniBatch(
                net,
                allocator,
                inputs,
                targets,
                num_samples,
                config.batch_size,
                config.learning_rate,
                config.activation_fn,
                config.activation_derivative,
            );

        loss_history[epoch] = loss_val;
        epochs_trained = epoch + 1;

        // Early stopping check
        if (config.patience > 0) {
            if (loss_val < best_loss - config.min_delta) {
                best_loss = loss_val;
                patience_counter = 0;
            } else {
                patience_counter += 1;
                if (patience_counter >= config.patience) {
                    early_stopped = true;
                    break;
                }
            }
        }
    }

    // Trim loss history to actual epochs trained
    const trimmed_history = try allocator.alloc(f32, epochs_trained);
    @memcpy(trimmed_history, loss_history[0..epochs_trained]);
    allocator.free(loss_history);

    return .{
        .final_loss = trimmed_history[epochs_trained - 1],
        .epochs_trained = epochs_trained,
        .loss_history = trimmed_history,
        .early_stopped = early_stopped,
    };
}

fn trainEpochMiniBatch(
    net: *Network,
    allocator: std.mem.Allocator,
    inputs: []const f32,
    targets: []const f32,
    num_samples: usize,
    batch_size: usize,
    lr: f32,
    act_fn: ActivationFn,
    act_derivative: ActivationDerivativeFn,
) !f32 {
    const input_size = net.layer_sizes[0];
    const output_size = net.layer_sizes[net.layer_sizes.len - 1];

    var total_loss: f32 = 0;
    var batches: usize = 0;
    var offset: usize = 0;

    while (offset < num_samples) {
        const current_batch = @min(batch_size, num_samples - offset);
        const batch_inputs = inputs[offset * input_size ..][0 .. current_batch * input_size];
        const batch_targets = targets[offset * output_size ..][0 .. current_batch * output_size];

        total_loss += try network.trainStepMseBatch(
            net,
            allocator,
            batch_inputs,
            batch_targets,
            current_batch,
            lr,
            act_fn,
            act_derivative,
        );

        batches += 1;
        offset += current_batch;
    }

    return total_loss / @as(f32, @floatFromInt(batches));
}

/// Evaluate network on test data. Returns MSE loss.
pub fn evaluate(
    net: *const Network,
    allocator: std.mem.Allocator,
    inputs: []const f32,
    targets: []const f32,
    act_fn: ActivationFn,
) !f32 {
    const input_size = net.layer_sizes[0];
    const output_size = net.layer_sizes[net.layer_sizes.len - 1];
    const num_samples = inputs.len / input_size;

    var total_loss: f32 = 0;
    for (0..num_samples) |i| {
        const input = inputs[i * input_size ..][0..input_size];
        const target = targets[i * output_size ..][0..output_size];
        const pred = try net.forward(allocator, input, act_fn);
        defer allocator.free(pred);
        total_loss += loss.mse(pred, target);
    }

    return total_loss / @as(f32, @floatFromInt(num_samples));
}

/// Compute accuracy for classification (single output, threshold 0.5).
pub fn binaryAccuracy(
    net: *const Network,
    allocator: std.mem.Allocator,
    inputs: []const f32,
    targets: []const f32,
    act_fn: ActivationFn,
) !f32 {
    const input_size = net.layer_sizes[0];
    const num_samples = inputs.len / input_size;

    var correct: usize = 0;
    for (0..num_samples) |i| {
        const input = inputs[i * input_size ..][0..input_size];
        const pred = try net.forward(allocator, input, act_fn);
        defer allocator.free(pred);

        const predicted_class: u1 = if (pred[0] > 0.5) 1 else 0;
        const actual_class: u1 = if (targets[i] > 0.5) 1 else 0;
        if (predicted_class == actual_class) correct += 1;
    }

    return @as(f32, @floatFromInt(correct)) / @as(f32, @floatFromInt(num_samples));
}

test "training config defaults" {
    const config = TrainingConfig{};
    try std.testing.expectEqual(@as(f32, 0.01), config.learning_rate);
    try std.testing.expectEqual(@as(usize, 100), config.epochs);
}

test "train simple network" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);

    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();

    // XOR-like training data
    const inputs = [_]f32{ 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0 };
    const targets = [_]f32{ 0.0, 1.0, 1.0, 0.0 };

    var result = try train(&net, gpa, &inputs, &targets, .{
        .epochs = 10,
        .learning_rate = 0.5,
    });
    defer result.deinit(gpa);

    try std.testing.expect(result.epochs_trained == 10);
    try std.testing.expect(result.loss_history != null);
}
