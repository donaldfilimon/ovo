//! Ovo: feedforward neural network in Zig.
//!
//! Re-exports: network, layer, activation, loss, csv, cli.
const std = @import("std");
const Io = std.Io;

pub const network = @import("network.zig");
pub const layer = @import("layer.zig");
pub const activation = @import("activation.zig");
pub const loss = @import("loss.zig");
pub const csv = @import("csv.zig");
pub const cli = @import("cli.zig");

pub const Network = network.Network;
pub const Gradients = network.Gradients;
pub const trainStepMse = network.trainStepMse;
pub const trainStepMseBatch = network.trainStepMseBatch;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
