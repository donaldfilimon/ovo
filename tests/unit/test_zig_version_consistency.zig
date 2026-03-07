const std = @import("std");
const builtin = @import("builtin");
const ovo = @import("ovo");

comptime {
    _ = ovo;
}

test "active zig version matches .zigversion and build.zig.zon minimum" {
    const zigversion_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        ".zigversion",
        std.testing.allocator,
        .limited(256),
    );
    defer std.testing.allocator.free(zigversion_bytes);

    const pinned_version = std.mem.trim(u8, zigversion_bytes, " \t\r\n");
    try std.testing.expect(pinned_version.len > 0);
    try std.testing.expectEqualStrings(pinned_version, builtin.zig_version_string);

    const zon_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig.zon",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(zon_bytes);

    const minimum = extractQuotedField(zon_bytes, ".minimum_zig_version") orelse return error.MissingMinimumZigVersion;
    try std.testing.expectEqualStrings(pinned_version, minimum);
}

fn extractQuotedField(bytes: []const u8, field_name: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, bytes, field_name) orelse return null;
    const rest = bytes[field_start + field_name.len ..];
    const first_quote_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const tail = rest[first_quote_rel + 1 ..];
    const second_quote_rel = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..second_quote_rel];
}
