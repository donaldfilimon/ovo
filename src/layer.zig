//! Layer descriptor and offset helpers for contiguous weight/bias storage.
//! Weights are stored row-major per layer: layer l has shape [out_size][in_size],
//! flattened as [out_size * in_size]. Biases are [out_size] per layer.
const std = @import("std");

/// Given layer_sizes (e.g. [2, 4, 4, 1]), returns the start index into the
/// concatenated weights array for layer `layer_index` (0 = first hidden layer).
/// Layer l connects layer_sizes[l] -> layer_sizes[l+1], so weight count is
/// layer_sizes[l+1] * layer_sizes[l].
pub fn startWeight(layer_sizes: []const usize, layer_index: usize) usize {
    var offset: usize = 0;
    for (layer_sizes[0..layer_index], 0..) |in_size, i| {
        const out_size = layer_sizes[i + 1];
        offset += out_size * in_size;
    }
    return offset;
}

/// Returns the start index into the concatenated biases array for layer `layer_index`.
/// Bias count per layer l is layer_sizes[l+1].
pub fn startBias(layer_sizes: []const usize, layer_index: usize) usize {
    var offset: usize = 0;
    for (0..layer_index) |i| {
        offset += layer_sizes[i + 1];
    }
    return offset;
}

/// Number of weight elements for layer `layer_index`.
pub fn weightCount(layer_sizes: []const usize, layer_index: usize) usize {
    return layer_sizes[layer_index] * layer_sizes[layer_index + 1];
}

/// Number of bias elements for layer `layer_index`.
pub fn biasCount(layer_sizes: []const usize, layer_index: usize) usize {
    return layer_sizes[layer_index + 1];
}

/// Total number of weight elements across all layers.
pub fn totalWeightCount(layer_sizes: []const usize) usize {
    var n: usize = 0;
    for (0..layer_sizes.len - 1) |i| {
        n += weightCount(layer_sizes, i);
    }
    return n;
}

/// Total number of bias elements across all layers.
pub fn totalBiasCount(layer_sizes: []const usize) usize {
    var n: usize = 0;
    for (1..layer_sizes.len) |i| {
        n += layer_sizes[i];
    }
    return n;
}

test "layer offsets" {
    const sizes = [_]usize{ 2, 4, 4, 1 };
    try std.testing.expectEqual(@as(usize, 0), startWeight(&sizes, 0));
    try std.testing.expectEqual(@as(usize, 2 * 4), startWeight(&sizes, 1));
    try std.testing.expectEqual(@as(usize, 2 * 4 + 4 * 4), startWeight(&sizes, 2));

    try std.testing.expectEqual(@as(usize, 0), startBias(&sizes, 0));
    try std.testing.expectEqual(@as(usize, 4), startBias(&sizes, 1));
    try std.testing.expectEqual(@as(usize, 4 + 4), startBias(&sizes, 2));

    try std.testing.expectEqual(@as(usize, 2 * 4 + 4 * 4 + 4 * 1), totalWeightCount(&sizes));
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1), totalBiasCount(&sizes));
}
