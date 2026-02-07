//! Cryptographic hashing utilities for ovo package manager.
//! Provides SHA256 and other hash functions for integrity verification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Blake3 = std.crypto.hash.Blake3;

/// Hash algorithm types.
pub const Algorithm = enum {
    sha256,
    sha512,
    blake3,

    pub fn digestLength(self: Algorithm) usize {
        return switch (self) {
            .sha256 => Sha256.digest_length,
            .sha512 => Sha512.digest_length,
            .blake3 => Blake3.digest_length,
        };
    }
};

/// A hash digest with its algorithm.
pub const Digest = struct {
    bytes: [64]u8, // Max size for sha512
    len: usize,
    algorithm: Algorithm,

    /// Convert to lowercase hex string.
    pub fn toHex(self: *const Digest, allocator: Allocator) ![]u8 {
        const hex = try allocator.alloc(u8, self.len * 2);
        const charset = "0123456789abcdef";
        for (self.bytes[0..self.len], 0..) |byte, i| {
            hex[i * 2] = charset[byte >> 4];
            hex[i * 2 + 1] = charset[byte & 0x0F];
        }
        return hex;
    }

    /// Get the digest bytes as a slice.
    pub fn slice(self: *const Digest) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Check equality with another digest.
    pub fn eql(self: *const Digest, other: *const Digest) bool {
        if (self.algorithm != other.algorithm or self.len != other.len) {
            return false;
        }
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    /// Parse from hex string.
    pub fn fromHex(hex: []const u8, algorithm: Algorithm) !Digest {
        const expected_len = algorithm.digestLength();
        if (hex.len != expected_len * 2) {
            return error.InvalidLength;
        }

        var digest = Digest{
            .bytes = undefined,
            .len = expected_len,
            .algorithm = algorithm,
        };

        for (0..expected_len) |i| {
            const high = hexCharToNibble(hex[i * 2]) orelse return error.InvalidHexChar;
            const low = hexCharToNibble(hex[i * 2 + 1]) orelse return error.InvalidHexChar;
            digest.bytes[i] = (@as(u8, high) << 4) | @as(u8, low);
        }

        return digest;
    }
};

fn hexCharToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Hash data using SHA256.
pub fn sha256(data: []const u8) Digest {
    var digest = Digest{
        .bytes = undefined,
        .len = Sha256.digest_length,
        .algorithm = .sha256,
    };
    Sha256.hash(data, digest.bytes[0..Sha256.digest_length], .{});
    return digest;
}

/// Hash data using SHA512.
pub fn sha512(data: []const u8) Digest {
    var digest = Digest{
        .bytes = undefined,
        .len = Sha512.digest_length,
        .algorithm = .sha512,
    };
    Sha512.hash(data, digest.bytes[0..Sha512.digest_length], .{});
    return digest;
}

/// Hash data using BLAKE3.
pub fn blake3(data: []const u8) Digest {
    var digest = Digest{
        .bytes = undefined,
        .len = Blake3.digest_length,
        .algorithm = .blake3,
    };
    Blake3.hash(data, digest.bytes[0..Blake3.digest_length], .{});
    return digest;
}

/// Streaming hash context for large data.
pub fn HashContext(comptime algo: Algorithm) type {
    const Hasher = switch (algo) {
        .sha256 => Sha256,
        .sha512 => Sha512,
        .blake3 => Blake3,
    };

    return struct {
        hasher: Hasher,

        const Self = @This();

        pub fn init() Self {
            return .{ .hasher = Hasher.init(.{}) };
        }

        pub fn update(self: *Self, data: []const u8) void {
            self.hasher.update(data);
        }

        pub fn final(self: *Self) Digest {
            var digest = Digest{
                .bytes = undefined,
                .len = Hasher.digest_length,
                .algorithm = algo,
            };
            self.hasher.final(digest.bytes[0..Hasher.digest_length]);
            return digest;
        }
    };
}

/// Hash a file using the specified algorithm.
pub fn hashFile(allocator: Allocator, path: []const u8, algorithm: Algorithm) !Digest {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return hashReader(allocator, file.reader().any(), algorithm);
}

/// Hash from a reader using the specified algorithm.
pub fn hashReader(_: Allocator, reader: std.io.AnyReader, algorithm: Algorithm) !Digest {
    switch (algorithm) {
        .sha256 => {
            var ctx = HashContext(.sha256).init();
            var buf: [8192]u8 = undefined;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                ctx.update(buf[0..n]);
            }
            return ctx.final();
        },
        .sha512 => {
            var ctx = HashContext(.sha512).init();
            var buf: [8192]u8 = undefined;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                ctx.update(buf[0..n]);
            }
            return ctx.final();
        },
        .blake3 => {
            var ctx = HashContext(.blake3).init();
            var buf: [8192]u8 = undefined;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                ctx.update(buf[0..n]);
            }
            return ctx.final();
        },
    }
}

/// Verify data against an expected hash.
pub fn verify(data: []const u8, expected_hex: []const u8, algorithm: Algorithm) !bool {
    const expected = try Digest.fromHex(expected_hex, algorithm);
    const actual = switch (algorithm) {
        .sha256 => sha256(data),
        .sha512 => sha512(data),
        .blake3 => blake3(data),
    };
    return actual.eql(&expected);
}

/// Verify a file against an expected hash.
pub fn verifyFile(allocator: Allocator, path: []const u8, expected_hex: []const u8, algorithm: Algorithm) !bool {
    const expected = try Digest.fromHex(expected_hex, algorithm);
    const actual = try hashFile(allocator, path, algorithm);
    return actual.eql(&expected);
}

/// Subresource Integrity (SRI) format: algorithm-base64digest
pub const SriHash = struct {
    algorithm: Algorithm,
    digest: Digest,

    pub fn parse(sri: []const u8) !SriHash {
        // Find the dash separator
        const dash_pos = std.mem.indexOf(u8, sri, "-") orelse return error.InvalidFormat;

        const algo_str = sri[0..dash_pos];
        const base64_str = sri[dash_pos + 1 ..];

        const algorithm: Algorithm = if (std.mem.eql(u8, algo_str, "sha256"))
            .sha256
        else if (std.mem.eql(u8, algo_str, "sha512"))
            .sha512
        else if (std.mem.eql(u8, algo_str, "blake3"))
            .blake3
        else
            return error.UnsupportedAlgorithm;

        var digest = Digest{
            .bytes = undefined,
            .len = algorithm.digestLength(),
            .algorithm = algorithm,
        };

        // Decode base64
        const decoder = std.base64.standard;
        const decoded_len = decoder.Decoder.calcSizeForSlice(base64_str) catch return error.InvalidBase64;
        if (decoded_len != digest.len) {
            return error.InvalidLength;
        }

        decoder.Decoder.decode(digest.bytes[0..digest.len], base64_str) catch return error.InvalidBase64;

        return .{
            .algorithm = algorithm,
            .digest = digest,
        };
    }

    pub fn format(self: *const SriHash, allocator: Allocator) ![]u8 {
        const algo_str = switch (self.algorithm) {
            .sha256 => "sha256",
            .sha512 => "sha512",
            .blake3 => "blake3",
        };

        const encoder = std.base64.standard;
        const encoded_len = encoder.Encoder.calcSize(self.digest.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        _ = encoder.Encoder.encode(encoded, self.digest.slice());

        const result = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ algo_str, encoded });
        allocator.free(encoded);
        return result;
    }
};

/// Create an SRI hash from data.
pub fn createSri(data: []const u8, algorithm: Algorithm) SriHash {
    const digest = switch (algorithm) {
        .sha256 => sha256(data),
        .sha512 => sha512(data),
        .blake3 => blake3(data),
    };
    return .{
        .algorithm = algorithm,
        .digest = digest,
    };
}

test "sha256 hash" {
    const data = "hello world";
    const digest = sha256(data);
    const allocator = std.testing.allocator;
    const hex = try digest.toHex(allocator);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        hex,
    );
}

test "verify hash" {
    const data = "hello world";
    const valid = try verify(
        data,
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        .sha256,
    );
    try std.testing.expect(valid);
}

test "streaming hash" {
    var ctx = HashContext(.sha256).init();
    ctx.update("hello ");
    ctx.update("world");
    const digest = ctx.final();
    const allocator = std.testing.allocator;
    const hex = try digest.toHex(allocator);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        hex,
    );
}
