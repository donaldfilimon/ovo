//! CLI argument parsing for neural network training.
//!
//! Provides command-line interface utilities for training and inference.
const std = @import("std");
const network = @import("network.zig");
const trainer = @import("trainer.zig");
const csv = @import("csv.zig");
const activation = @import("activation.zig");

/// Training configuration from command line.
pub const TrainConfig = struct {
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    model_file: ?[]const u8 = null,
    epochs: usize = 100,
    learning_rate: f32 = 0.01,
    batch_size: usize = 32,
    hidden_layers: []const usize = &.{ 64, 32 },
    verbose: bool = false,
    early_stopping: bool = false,
    patience: usize = 10,
    activation: ActivationType = .sigmoid,

    pub const ActivationType = enum {
        sigmoid,
        relu,
        tanh,
        leaky_relu,
    };

    pub fn getActivationFn(self: TrainConfig) network.ActivationFn {
        return switch (self.activation) {
            .sigmoid => activation.sigmoid,
            .relu => activation.relu,
            .tanh => activation.tanh,
            .leaky_relu => activation.leakyReluDefault,
        };
    }

    pub fn getActivationDerivative(self: TrainConfig) network.ActivationDerivativeFn {
        return switch (self.activation) {
            .sigmoid => activation.sigmoidDerivative,
            .relu => activation.reluDerivative,
            .tanh => activation.tanhDerivative,
            .leaky_relu => activation.leakyReluDerivativeDefault,
        };
    }
};

/// Parse training arguments from command line.
pub fn parseTrainArgs(allocator: std.mem.Allocator, args: []const []const u8) !TrainConfig {
    _ = allocator;
    var config = TrainConfig{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--epochs") and i + 1 < args.len) {
            i += 1;
            config.epochs = std.fmt.parseInt(usize, args[i], 10) catch 100;
        } else if ((std.mem.eql(u8, arg, "--lr") or std.mem.eql(u8, arg, "--learning-rate")) and i + 1 < args.len) {
            i += 1;
            config.learning_rate = std.fmt.parseFloat(f32, args[i]) catch 0.01;
        } else if ((std.mem.eql(u8, arg, "--batch") or std.mem.eql(u8, arg, "--batch-size")) and i + 1 < args.len) {
            i += 1;
            config.batch_size = std.fmt.parseInt(usize, args[i], 10) catch 32;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if ((std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) and i + 1 < args.len) {
            i += 1;
            config.input_file = args[i];
        } else if ((std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) and i + 1 < args.len) {
            i += 1;
            config.output_file = args[i];
        } else if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) and i + 1 < args.len) {
            i += 1;
            config.model_file = args[i];
        } else if (std.mem.eql(u8, arg, "--early-stopping")) {
            config.early_stopping = true;
        } else if (std.mem.eql(u8, arg, "--patience") and i + 1 < args.len) {
            i += 1;
            config.patience = std.fmt.parseInt(usize, args[i], 10) catch 10;
        } else if (std.mem.eql(u8, arg, "--activation") and i + 1 < args.len) {
            i += 1;
            config.activation = parseActivation(args[i]);
        }
    }

    return config;
}

fn parseActivation(s: []const u8) TrainConfig.ActivationType {
    if (std.mem.eql(u8, s, "relu")) return .relu;
    if (std.mem.eql(u8, s, "tanh")) return .tanh;
    if (std.mem.eql(u8, s, "leaky_relu") or std.mem.eql(u8, s, "leaky-relu")) return .leaky_relu;
    return .sigmoid;
}

/// Parse float arguments from command line.
pub fn parseFloatArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]f32 {
    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(allocator);

    for (args) |arg| {
        const val = std.fmt.parseFloat(f32, arg) catch continue;
        try list.append(allocator, val);
    }

    return list.toOwnedSlice(allocator);
}

/// Print training help message.
pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Neural Network Training CLI
        \\
        \\Usage: ovo neural train [options]
        \\
        \\Options:
        \\  -i, --input <file>       Input CSV file with training data
        \\  -o, --output <file>      Output file for predictions
        \\  -m, --model <file>       Model file to save/load
        \\  --epochs <n>             Number of training epochs (default: 100)
        \\  --lr, --learning-rate <r> Learning rate (default: 0.01)
        \\  --batch, --batch-size <n> Batch size (default: 32)
        \\  --activation <type>      Activation: sigmoid, relu, tanh, leaky_relu
        \\  --early-stopping         Enable early stopping
        \\  --patience <n>           Early stopping patience (default: 10)
        \\  -v, --verbose            Verbose output
        \\
        \\Examples:
        \\  ovo neural train -i data.csv --epochs 1000 --lr 0.001
        \\  ovo neural train -i data.csv -m model.bin --activation relu
        \\
    );
}

/// Format training progress for display.
pub fn formatProgress(
    writer: anytype,
    epoch: usize,
    total_epochs: usize,
    loss: f32,
    accuracy: ?f32,
) !void {
    const percent = @as(f32, @floatFromInt(epoch)) / @as(f32, @floatFromInt(total_epochs)) * 100.0;
    try writer.print("Epoch {d}/{d} ({d:.1}%) - Loss: {d:.6}", .{ epoch, total_epochs, percent, loss });
    if (accuracy) |acc| {
        try writer.print(" - Accuracy: {d:.2}%", .{acc * 100.0});
    }
    try writer.writeAll("\n");
}

test "parse train args" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--epochs", "50", "--lr", "0.1", "-v" };
    const config = try parseTrainArgs(gpa, &args);
    try std.testing.expectEqual(@as(usize, 50), config.epochs);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), config.learning_rate, 1e-6);
    try std.testing.expect(config.verbose);
}

test "parse float args" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "1.5", "invalid", "2.5", "3.0" };
    const floats = try parseFloatArgs(gpa, &args);
    defer gpa.free(floats);
    try std.testing.expectEqual(@as(usize, 3), floats.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), floats[0], 1e-6);
}
