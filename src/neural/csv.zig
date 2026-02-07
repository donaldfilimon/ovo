//! CSV parsing for neural network training data.
//!
//! Format: each row = comma-separated floats. Last column = target(s), rest = features.
//! Rows must have consistent column count. Empty lines are skipped.
const std = @import("std");

/// Parsed training data. Caller owns `inputs` and `targets`; free with allocator.
pub const TrainingData = struct {
    /// Flat [num_rows * input_size] feature values.
    inputs: []const f32,
    /// Flat [num_rows * output_size] target values. Currently output_size is always 1.
    targets: []const f32,
    input_size: usize,
    output_size: usize,
    num_rows: usize,

    pub fn deinit(self: *TrainingData, allocator: std.mem.Allocator) void {
        allocator.free(self.inputs);
        allocator.free(self.targets);
        self.* = undefined;
    }
};

/// Parse a CSV file into training data. Format: each row = features...,target(s).
/// Uses last column as target(s); rest are features. Returns error if parse fails.
pub fn parseTrainingCsv(
    allocator: std.mem.Allocator,
    data: []const u8,
    err_writer: anytype,
) !TrainingData {
    var inputs_list: std.ArrayList(f32) = .empty;
    defer inputs_list.deinit(allocator);
    var targets_list: std.ArrayList(f32) = .empty;
    defer targets_list.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, data, '\n');
    var input_size: ?usize = null;
    var rows: usize = 0;
    var row_vals: std.ArrayList(f32) = .empty;
    defer row_vals.deinit(allocator);

    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        row_vals.clearRetainingCapacity();
        var col_it = std.mem.splitScalar(u8, line, ',');
        while (col_it.next()) |token_raw| {
            const token = std.mem.trim(u8, token_raw, " \t");
            if (token.len == 0) continue;
            const v = std.fmt.parseFloat(f32, token) catch {
                try err_writer.print("csv: invalid float in token: {s}\n", .{token});
                return error.InvalidCsv;
            };
            try row_vals.append(allocator, v);
        }
        if (row_vals.items.len < 2) continue;
        if (input_size == null) {
            input_size = row_vals.items.len - 1;
        } else if (row_vals.items.len != input_size.? + 1) {
            try err_writer.print("csv: row {d} has inconsistent column count (expected {d} features + 1 target)\n", .{ rows + 1, input_size.? });
            return error.InconsistentColumns;
        }
        const in_size = input_size.?;
        try inputs_list.appendSlice(allocator, row_vals.items[0..in_size]);
        try targets_list.append(allocator, row_vals.items[in_size]);
        rows += 1;
    }

    if (rows == 0 or input_size == null) {
        try err_writer.print("csv: no valid data rows found\n", .{});
        return error.NoData;
    }

    return .{
        .inputs = try inputs_list.toOwnedSlice(allocator),
        .targets = try targets_list.toOwnedSlice(allocator),
        .input_size = input_size.?,
        .output_size = 1,
        .num_rows = rows,
    };
}

/// Parse CSV with multiple target columns.
pub fn parseTrainingCsvMultiTarget(
    allocator: std.mem.Allocator,
    data: []const u8,
    num_targets: usize,
    err_writer: anytype,
) !TrainingData {
    var inputs_list: std.ArrayList(f32) = .empty;
    defer inputs_list.deinit(allocator);
    var targets_list: std.ArrayList(f32) = .empty;
    defer targets_list.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, data, '\n');
    var input_size: ?usize = null;
    var rows: usize = 0;
    var row_vals: std.ArrayList(f32) = .empty;
    defer row_vals.deinit(allocator);

    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        row_vals.clearRetainingCapacity();
        var col_it = std.mem.splitScalar(u8, line, ',');
        while (col_it.next()) |token_raw| {
            const token = std.mem.trim(u8, token_raw, " \t");
            if (token.len == 0) continue;
            const v = std.fmt.parseFloat(f32, token) catch {
                try err_writer.print("csv: invalid float in token: {s}\n", .{token});
                return error.InvalidCsv;
            };
            try row_vals.append(allocator, v);
        }
        if (row_vals.items.len < num_targets + 1) continue;
        if (input_size == null) {
            input_size = row_vals.items.len - num_targets;
        } else if (row_vals.items.len != input_size.? + num_targets) {
            try err_writer.print("csv: row {d} has inconsistent column count\n", .{rows + 1});
            return error.InconsistentColumns;
        }
        const in_size = input_size.?;
        try inputs_list.appendSlice(allocator, row_vals.items[0..in_size]);
        try targets_list.appendSlice(allocator, row_vals.items[in_size..]);
        rows += 1;
    }

    if (rows == 0 or input_size == null) {
        try err_writer.print("csv: no valid data rows found\n", .{});
        return error.NoData;
    }

    return .{
        .inputs = try inputs_list.toOwnedSlice(allocator),
        .targets = try targets_list.toOwnedSlice(allocator),
        .input_size = input_size.?,
        .output_size = num_targets,
        .num_rows = rows,
    };
}

/// Skip header row and parse CSV.
pub fn parseTrainingCsvWithHeader(
    allocator: std.mem.Allocator,
    data: []const u8,
    err_writer: anytype,
) !TrainingData {
    // Find first newline
    var line_it = std.mem.splitScalar(u8, data, '\n');
    _ = line_it.next(); // Skip header
    const rest = line_it.rest();
    return parseTrainingCsv(allocator, rest, err_writer);
}

/// Normalize data to [0, 1] range.
pub fn normalize(data: []f32) struct { min: f32, max: f32 } {
    if (data.len == 0) return .{ .min = 0, .max = 1 };

    var min_val = data[0];
    var max_val = data[0];
    for (data[1..]) |v| {
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }

    const range = max_val - min_val;
    if (range > 0) {
        for (data) |*v| {
            v.* = (v.* - min_val) / range;
        }
    }

    return .{ .min = min_val, .max = max_val };
}

/// Standardize data to zero mean and unit variance.
pub fn standardize(data: []f32) struct { mean: f32, std: f32 } {
    if (data.len == 0) return .{ .mean = 0, .std = 1 };

    var sum: f32 = 0;
    for (data) |v| sum += v;
    const mean = sum / @as(f32, @floatFromInt(data.len));

    var variance: f32 = 0;
    for (data) |v| {
        const diff = v - mean;
        variance += diff * diff;
    }
    variance /= @as(f32, @floatFromInt(data.len));
    const std_dev = @sqrt(variance);

    if (std_dev > 0) {
        for (data) |*v| {
            v.* = (v.* - mean) / std_dev;
        }
    }

    return .{ .mean = mean, .std = std_dev };
}

test "parse training csv" {
    const gpa = std.testing.allocator;
    const data = "0.5,-0.3,0.8\n0.2,0.9,0.1\n";
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var td = try parseTrainingCsv(gpa, data, &writer);
    defer td.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), td.num_rows);
    try std.testing.expectEqual(@as(usize, 2), td.input_size);
    try std.testing.expectEqual(@as(usize, 1), td.output_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), td.inputs[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), td.targets[0], 1e-6);
}

test "normalize" {
    var data = [_]f32{ 0.0, 50.0, 100.0 };
    const stats = normalize(&data);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), data[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), data[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), data[2], 1e-6);
    try std.testing.expectEqual(@as(f32, 0.0), stats.min);
    try std.testing.expectEqual(@as(f32, 100.0), stats.max);
}

test "standardize" {
    var data = [_]f32{ 1.0, 2.0, 3.0 };
    const stats = standardize(&data);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), stats.mean, 1e-6);
    // Check that mean is approximately 0
    var sum: f32 = 0;
    for (data) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sum / 3.0, 1e-5);
}
