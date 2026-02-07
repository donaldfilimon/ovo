//! Neural Network Module
//!
//! A complete feedforward neural network implementation with:
//! - Flexible architecture (arbitrary layer sizes)
//! - Multiple activation functions (sigmoid, relu, tanh, etc.)
//! - Various loss functions (MSE, cross-entropy, etc.)
//! - Training utilities with early stopping and batching
//! - CSV data loading with normalization
//!
//! ## Quick Start
//! ```zig
//! const neural = @import("ovo").neural;
//! const Network = neural.Network;
//!
//! // Create a network: 2 inputs -> 4 hidden -> 1 output
//! var prng = std.Random.DefaultPrng.init(42);
//! var net = try Network.initXavier(allocator, &[_]usize{ 2, 4, 1 }, prng.random());
//! defer net.deinit();
//!
//! // Forward pass
//! const input = [_]f32{ 0.5, -0.3 };
//! const output = try net.forward(allocator, &input, neural.activation.sigmoid);
//! defer allocator.free(output);
//!
//! // Training
//! const loss = try neural.trainStepMse(&net, allocator, &input, &target, 0.01,
//!     neural.activation.sigmoid, neural.activation.sigmoidDerivative);
//! ```
//!
//! ## Architecture
//! - Weights stored row-major: layer l connects sizes[l] -> sizes[l+1]
//! - Biases stored per output neuron
//! - Contiguous memory layout for cache efficiency

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Core Components
// ═══════════════════════════════════════════════════════════════════════════

/// Network architecture and forward/backward passes.
pub const network = @import("network.zig");

/// Layer utilities (weight/bias offsets, counts).
pub const layer = @import("layer.zig");

/// Activation functions and derivatives.
pub const activation = @import("activation.zig");

/// Loss functions and gradients.
pub const loss = @import("loss.zig");

/// High-level training utilities.
pub const trainer = @import("trainer.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Utilities
// ═══════════════════════════════════════════════════════════════════════════

/// CSV parsing for training data.
pub const csv = @import("csv.zig");

/// Command-line interface utilities.
pub const cli = @import("cli.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Re-exported Types (Convenience)
// ═══════════════════════════════════════════════════════════════════════════

/// Feedforward neural network.
pub const Network = network.Network;

/// Gradient storage for training.
pub const Gradients = network.Gradients;

/// Layer information.
pub const Layer = layer.Layer;

/// Parsed training data from CSV.
pub const TrainingData = csv.TrainingData;

/// Training configuration.
pub const TrainingConfig = trainer.TrainingConfig;

/// Training result with loss history.
pub const TrainingResult = trainer.TrainingResult;

// ═══════════════════════════════════════════════════════════════════════════
// Re-exported Functions (Convenience)
// ═══════════════════════════════════════════════════════════════════════════

/// Single SGD step with MSE loss.
pub const trainStepMse = network.trainStepMse;

/// Minibatch SGD step with MSE loss.
pub const trainStepMseBatch = network.trainStepMseBatch;

/// High-level training loop.
pub const train = trainer.train;

/// Evaluate network on test data.
pub const evaluate = trainer.evaluate;

/// Parse training data from CSV.
pub const parseTrainingCsv = csv.parseTrainingCsv;

// ═══════════════════════════════════════════════════════════════════════════
// CLI Exports
// ═══════════════════════════════════════════════════════════════════════════

/// CLI training configuration.
pub const TrainConfig = cli.TrainConfig;

/// Parse training arguments.
pub const parseTrainArgs = cli.parseTrainArgs;

/// Parse float arguments.
pub const parseFloatArgs = cli.parseFloatArgs;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test {
    std.testing.refAllDecls(@This());
}

test "neural module exports" {
    // Verify all key types are accessible
    _ = Network;
    _ = Gradients;
    _ = Layer;
    _ = TrainingData;
    _ = TrainingConfig;
    _ = activation.sigmoid;
    _ = activation.relu;
    _ = loss.mse;
    _ = layer.totalWeightCount;
}

test "end-to-end training" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);

    // Create a simple network
    const sizes = [_]usize{ 2, 4, 1 };
    var net = try Network.initXavier(gpa, &sizes, prng.random());
    defer net.deinit();

    // Simple training data (AND gate)
    const inputs = [_]f32{
        0.0, 0.0,
        0.0, 1.0,
        1.0, 0.0,
        1.0, 1.0,
    };
    const targets = [_]f32{ 0.0, 0.0, 0.0, 1.0 };

    // Train
    var result = try train(&net, gpa, &inputs, &targets, .{
        .epochs = 100,
        .learning_rate = 1.0,
        .batch_size = 0, // Full batch
    });
    defer result.deinit(gpa);

    // Verify training ran
    try std.testing.expect(result.epochs_trained > 0);
    try std.testing.expect(result.final_loss < 1.0);
}
