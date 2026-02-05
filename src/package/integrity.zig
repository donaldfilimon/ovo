//! Hash verification for package integrity.
//!
//! Provides SHA256 hash computation and verification for downloaded packages,
//! ensuring they haven't been tampered with or corrupted during transfer.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;
const fs = std.fs;

/// Hash representation as a fixed-size byte array.
pub const Hash = [Sha256.digest_length]u8;

/// Hash encoded as hexadecimal string.
pub const HashString = [Sha256.digest_length * 2]u8;

/// Errors that can occur during integrity operations.
pub const IntegrityError = error{
    HashMismatch,
    InvalidHashFormat,
    FileReadError,
    OutOfMemory,
} || fs.File.OpenError || fs.File.ReadError;

/// Result of a hash verification operation.
pub const VerificationResult = struct {
    valid: bool,
    expected: HashString,
    actual: HashString,

    pub fn format(
        self: VerificationResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.valid) {
            try writer.print("OK: {s}", .{self.actual});
        } else {
            try writer.print("MISMATCH: expected {s}, got {s}", .{ self.expected, self.actual });
        }
    }
};

/// Compute SHA256 hash of a byte slice.
pub fn hashBytes(data: []const u8) Hash {
    var hasher = Sha256.init(.{});
    hasher.update(data);
    return hasher.finalResult();
}

/// Compute SHA256 hash of a file.
pub fn hashFile(allocator: Allocator, path: []const u8) IntegrityError!Hash {
    const file = fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileReadError,
            else => err,
        };
    };
    defer file.close();

    return hashFileHandle(allocator, file);
}

/// Compute SHA256 hash from an open file handle.
pub fn hashFileHandle(allocator: Allocator, file: fs.File) IntegrityError!Hash {
    const buffer_size = 64 * 1024; // 64KB buffer
    const buffer = allocator.alloc(u8, buffer_size) catch return error.OutOfMemory;
    defer allocator.free(buffer);

    var hasher = Sha256.init(.{});

    while (true) {
        const bytes_read = file.read(buffer) catch return error.FileReadError;
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    return hasher.finalResult();
}

/// Compute SHA256 hash of a directory (recursive, deterministic order).
pub fn hashDirectory(allocator: Allocator, dir_path: []const u8) IntegrityError!Hash {
    var hasher = Sha256.init(.{});

    // Collect all file paths first for deterministic ordering
    var paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    try collectFilePaths(allocator, dir_path, &paths);

    // Sort paths for deterministic hashing
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Hash each file
    for (paths.items) |path| {
        // Include relative path in hash
        hasher.update(path);

        const file_hash = try hashFile(allocator, path);
        hasher.update(&file_hash);
    }

    return hasher.finalResult();
}

fn collectFilePaths(allocator: Allocator, dir_path: []const u8, paths: *std.ArrayList([]const u8)) !void {
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return error.FileReadError;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return error.FileReadError) |entry| {
        const full_path = fs.path.join(allocator, &.{ dir_path, entry.name }) catch return error.OutOfMemory;
        errdefer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                paths.append(full_path) catch return error.OutOfMemory;
            },
            .directory => {
                // Skip hidden directories and common non-content dirs
                if (entry.name[0] != '.' and !std.mem.eql(u8, entry.name, "zig-cache") and !std.mem.eql(u8, entry.name, "zig-out")) {
                    try collectFilePaths(allocator, full_path, paths);
                }
                allocator.free(full_path);
            },
            else => {
                allocator.free(full_path);
            },
        }
    }
}

/// Convert a hash to its hexadecimal string representation.
pub fn hashToString(hash: Hash) HashString {
    const hex_chars = "0123456789abcdef";
    var result: HashString = undefined;

    for (hash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return result;
}

/// Parse a hexadecimal string into a hash.
pub fn stringToHash(hex: []const u8) IntegrityError!Hash {
    if (hex.len != Sha256.digest_length * 2) {
        return error.InvalidHashFormat;
    }

    var result: Hash = undefined;

    for (0..Sha256.digest_length) |i| {
        const high = hexCharToNibble(hex[i * 2]) orelse return error.InvalidHashFormat;
        const low = hexCharToNibble(hex[i * 2 + 1]) orelse return error.InvalidHashFormat;
        result[i] = (high << 4) | low;
    }

    return result;
}

fn hexCharToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Verify that data matches an expected hash.
pub fn verifyBytes(data: []const u8, expected: Hash) VerificationResult {
    const actual = hashBytes(data);
    return .{
        .valid = std.mem.eql(u8, &actual, &expected),
        .expected = hashToString(expected),
        .actual = hashToString(actual),
    };
}

/// Verify that a file matches an expected hash.
pub fn verifyFile(allocator: Allocator, path: []const u8, expected: Hash) IntegrityError!VerificationResult {
    const actual = try hashFile(allocator, path);
    return .{
        .valid = std.mem.eql(u8, &actual, &expected),
        .expected = hashToString(expected),
        .actual = hashToString(actual),
    };
}

/// Verify using a hex string instead of raw hash.
pub fn verifyFileHex(allocator: Allocator, path: []const u8, expected_hex: []const u8) IntegrityError!VerificationResult {
    const expected = try stringToHash(expected_hex);
    return verifyFile(allocator, path, expected);
}

/// Subresource Integrity (SRI) format: "sha256-<base64>"
pub fn toSriFormat(hash: Hash) [51]u8 {
    const base64_encoder = std.base64.standard;
    var result: [51]u8 = undefined;
    @memcpy(result[0..7], "sha256-");
    _ = base64_encoder.Encoder.encode(result[7..], &hash);
    return result;
}

/// Parse SRI format hash.
pub fn fromSriFormat(sri: []const u8) IntegrityError!Hash {
    if (sri.len < 7 or !std.mem.startsWith(u8, sri, "sha256-")) {
        return error.InvalidHashFormat;
    }

    const base64_decoder = std.base64.standard;
    var result: Hash = undefined;
    base64_decoder.Decoder.decode(&result, sri[7..]) catch return error.InvalidHashFormat;
    return result;
}

// Tests
test "hash bytes" {
    const data = "hello world";
    const hash = hashBytes(data);
    const hex = hashToString(hash);

    // Known SHA256 of "hello world"
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        &hex,
    );
}

test "hash round trip" {
    const original = "test data for hashing";
    const hash = hashBytes(original);
    const hex = hashToString(hash);
    const recovered = try stringToHash(&hex);

    try std.testing.expectEqualSlices(u8, &hash, &recovered);
}

test "verify bytes" {
    const data = "hello world";
    const hash = hashBytes(data);

    const result = verifyBytes(data, hash);
    try std.testing.expect(result.valid);

    const wrong_result = verifyBytes("wrong data", hash);
    try std.testing.expect(!wrong_result.valid);
}

test "invalid hash format" {
    try std.testing.expectError(error.InvalidHashFormat, stringToHash("too short"));
    try std.testing.expectError(error.InvalidHashFormat, stringToHash("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "sri format" {
    const data = "test";
    const hash = hashBytes(data);
    const sri = toSriFormat(hash);

    try std.testing.expect(std.mem.startsWith(u8, &sri, "sha256-"));

    const recovered = try fromSriFormat(&sri);
    try std.testing.expectEqualSlices(u8, &hash, &recovered);
}
