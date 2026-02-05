//! Neural Network Module (Legacy)
//!
//! The original OVO project was a feedforward neural network implementation.
//! This module preserves that functionality for backwards compatibility.
//!
//! For new machine learning projects, consider using dedicated ML libraries
//! that are more feature-complete and optimized.
//!
//! ## Example Usage
//! ```zig
//! const neural = @import("ovo").neural;
//! const Network = neural.Network;
//!
//! var net = try Network.initXavier(allocator, &[_]usize{ 2, 4, 1 }, prng.random());
//! defer net.deinit();
//!
//! const output = try net.forward(allocator, &input, neural.activation.sigmoid);
//! ```

const std = @import("std");

// Core neural network components
pub const network = @import("network.zig");
pub const layer = @import("layer.zig");
pub const activation = @import("activation.zig");
pub const loss = @import("loss.zig");
pub const trainer = @import("trainer.zig");

// Utilities
pub const csv = @import("csv.zig");
pub const cli = @import("cli.zig");

// Re-export primary types for convenience
pub const Network = network.Network;
pub const Gradients = network.Gradients;
pub const Layer = layer.Layer;

// Re-export training functions
pub const trainStepMse = network.trainStepMse;
pub const trainStepMseBatch = network.trainStepMseBatch;

// Re-export CLI types
pub const TrainConfig = cli.TrainConfig;
pub const parseTrainArgs = cli.parseTrainArgs;
pub const parseFloatArgs = cli.parseFloatArgs;

test {
    std.testing.refAllDecls(@This());
}

test "neural module exports" {
    // Verify all key types are accessible
    _ = Network;
    _ = Layer;
    _ = Gradients;
    _ = activation.sigmoid;
    _ = loss.mse;
}
