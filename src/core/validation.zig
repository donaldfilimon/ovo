//! Validation helpers for core data structures.

const std = @import("std");

/// Returns true if any duplicate names exist in `items`.
pub fn hasDuplicateName(comptime T: type, items: []const T, name_fn: fn (T) []const u8) bool {
    for (items, 0..) |item1, i| {
        const name1 = name_fn(item1);
        for (items[i + 1 ..]) |item2| {
            if (std.mem.eql(u8, name1, name_fn(item2))) {
                return true;
            }
        }
    }
    return false;
}
