//! CLI argument parsing for the ovo neural network CLI.
//!
//! Supports `train [--layers a,b,c] [--batch N] <file.csv> <epochs>` and float args for inference.
const std = @import("std");

/// Configuration for the `train` subcommand. Caller must free `layers_override` if non-null.
pub const TrainConfig = struct {
    path: []const u8,
    epochs: u32,
    batch_size: usize,
    layers_override: ?[]const usize,
    learning_rate: f32,

    pub fn deinit(self: *TrainConfig, allocator: std.mem.Allocator) void {
        if (self.layers_override) |layers| allocator.free(layers);
        self.* = undefined;
    }
};

/// Parse `train [--layers a,b,c] [--batch N] <file.csv> <epochs>`.
/// Returns config or error; caller owns layers_override and must free via deinit.
pub fn parseTrainArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    err_writer: anytype,
) !TrainConfig {
    var batch_size: usize = 0;
    var layers_override: ?[]const usize = null;
    errdefer if (layers_override) |layers| allocator.free(layers);
    var positional_start: usize = 0;
    var i: usize = 0;

    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--batch")) {
            if (i + 1 >= args.len) {
                try err_writer.print("cli: missing value for --batch\n", .{});
                return error.InvalidInput;
            }
            batch_size = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                try err_writer.print("cli: invalid --batch: {s}\n", .{args[i + 1]});
                return error.InvalidInput;
            };
            if (batch_size == 0) {
                try err_writer.print("cli: --batch must be >= 1\n", .{});
                return error.InvalidInput;
            }
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--layers")) {
            if (i + 1 >= args.len) {
                try err_writer.print("cli: missing value for --layers\n", .{});
                return error.InvalidInput;
            }
            var list: std.ArrayList(usize) = .empty;
            defer list.deinit(allocator);
            var part_it = std.mem.splitScalar(u8, args[i + 1], ',');
            while (part_it.next()) |part| {
                const s = std.mem.trim(u8, part, " \t");
                if (s.len == 0) continue;
                const v = std.fmt.parseInt(usize, s, 10) catch {
                    try err_writer.print("cli: invalid --layers token: {s}\n", .{s});
                    return error.InvalidInput;
                };
                try list.append(allocator, v);
            }
            if (list.items.len < 2) {
                try err_writer.print("cli: --layers must have at least 2 values (e.g. 2,4,1)\n", .{});
                return error.InvalidInput;
            }
            layers_override = try std.mem.Allocator.dupe(allocator, usize, list.items);
            i += 2;
            continue;
        }
        positional_start = i;
        break;
    }

    const positional = args[positional_start..];
    if (positional.len < 2) {
        try err_writer.print("Usage: ovo train [--layers a,b,c] [--batch N] <file.csv> <epochs>\n", .{});
        return error.InvalidInput;
    }

    const path = positional[0];
    const epochs = std.fmt.parseInt(u32, positional[1], 10) catch {
        try err_writer.print("cli: invalid epochs: {s}\n", .{positional[1]});
        return error.InvalidInput;
    };

    return .{
        .path = path,
        .epochs = epochs,
        .batch_size = batch_size,
        .layers_override = layers_override,
        .learning_rate = 0.1,
    };
}

/// Parse a slice of strings as floats. Returns owned slice; caller must free.
pub fn parseFloatArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    err_writer: anytype,
) ![]f32 {
    var list: std.ArrayList(f32) = .empty;
    defer list.deinit(allocator);
    for (args) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        if (trimmed.len == 0) continue;
        const v = std.fmt.parseFloat(f32, trimmed) catch {
            try err_writer.print("cli: invalid float: {s}\n", .{arg});
            return error.InvalidInput;
        };
        try list.append(allocator, v);
    }
    return list.toOwnedSlice(allocator);
}
