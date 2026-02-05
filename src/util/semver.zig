//! Semantic Versioning (SemVer) parsing and comparison for ovo package manager.
//! Implements SemVer 2.0.0 specification: https://semver.org/

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error types for version parsing.
pub const ParseError = error{
    InvalidVersion,
    InvalidMajor,
    InvalidMinor,
    InvalidPatch,
    InvalidPrerelease,
    InvalidBuildMetadata,
    OutOfMemory,
};

/// A parsed semantic version.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: ?[]const u8,
    build_metadata: ?[]const u8,
    allocator: ?Allocator,

    /// Create a version without prerelease/build metadata.
    pub fn init(major: u32, minor: u32, patch: u32) Version {
        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
            .prerelease = null,
            .build_metadata = null,
            .allocator = null,
        };
    }

    /// Free allocated memory.
    pub fn deinit(self: *Version) void {
        if (self.allocator) |alloc| {
            if (self.prerelease) |pr| alloc.free(pr);
            if (self.build_metadata) |bm| alloc.free(bm);
        }
    }

    /// Format version as string.
    pub fn format(
        self: Version,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.prerelease) |pr| {
            try writer.print("-{s}", .{pr});
        }
        if (self.build_metadata) |bm| {
            try writer.print("+{s}", .{bm});
        }
    }

    /// Convert to string.
    pub fn toString(self: *const Version, allocator: Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        try list.writer().print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.prerelease) |pr| {
            try list.writer().print("-{s}", .{pr});
        }
        if (self.build_metadata) |bm| {
            try list.writer().print("+{s}", .{bm});
        }

        return list.toOwnedSlice();
    }

    /// Compare two versions (ignoring build metadata per SemVer spec).
    pub fn compare(self: Version, other: Version) std.math.Order {
        // Compare major.minor.patch
        if (self.major != other.major) {
            return std.math.order(self.major, other.major);
        }
        if (self.minor != other.minor) {
            return std.math.order(self.minor, other.minor);
        }
        if (self.patch != other.patch) {
            return std.math.order(self.patch, other.patch);
        }

        // Prerelease comparison
        return comparePrereleases(self.prerelease, other.prerelease);
    }

    /// Check if this version is less than another.
    pub fn lessThan(self: Version, other: Version) bool {
        return self.compare(other) == .lt;
    }

    /// Check if this version is greater than another.
    pub fn greaterThan(self: Version, other: Version) bool {
        return self.compare(other) == .gt;
    }

    /// Check if versions are equal (ignoring build metadata).
    pub fn eql(self: Version, other: Version) bool {
        return self.compare(other) == .eq;
    }

    /// Check if this version satisfies a version range.
    pub fn satisfies(self: Version, range: *const Range) bool {
        return range.contains(self);
    }

    /// Increment major version (reset minor and patch).
    pub fn incrementMajor(self: Version) Version {
        return .{
            .major = self.major + 1,
            .minor = 0,
            .patch = 0,
            .prerelease = null,
            .build_metadata = null,
            .allocator = null,
        };
    }

    /// Increment minor version (reset patch).
    pub fn incrementMinor(self: Version) Version {
        return .{
            .major = self.major,
            .minor = self.minor + 1,
            .patch = 0,
            .prerelease = null,
            .build_metadata = null,
            .allocator = null,
        };
    }

    /// Increment patch version.
    pub fn incrementPatch(self: Version) Version {
        return .{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch + 1,
            .prerelease = null,
            .build_metadata = null,
            .allocator = null,
        };
    }
};

fn comparePrereleases(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    // No prerelease has higher precedence than any prerelease
    if (a == null and b == null) return .eq;
    if (a == null) return .gt; // Release > prerelease
    if (b == null) return .lt; // Prerelease < release

    // Compare identifiers
    var a_iter = std.mem.splitScalar(u8, a.?, '.');
    var b_iter = std.mem.splitScalar(u8, b.?, '.');

    while (true) {
        const a_id = a_iter.next();
        const b_id = b_iter.next();

        if (a_id == null and b_id == null) return .eq;
        if (a_id == null) return .lt; // Fewer identifiers = lower
        if (b_id == null) return .gt;

        const cmp = compareIdentifiers(a_id.?, b_id.?);
        if (cmp != .eq) return cmp;
    }
}

fn compareIdentifiers(a: []const u8, b: []const u8) std.math.Order {
    const a_num = std.fmt.parseInt(u32, a, 10) catch null;
    const b_num = std.fmt.parseInt(u32, b, 10) catch null;

    // Numeric identifiers have lower precedence than alphanumeric
    if (a_num != null and b_num != null) {
        return std.math.order(a_num.?, b_num.?);
    }
    if (a_num != null) return .lt;
    if (b_num != null) return .gt;

    // Alphanumeric comparison
    return std.mem.order(u8, a, b);
}

/// Parse a version string.
pub fn parse(allocator: Allocator, str: []const u8) !Version {
    var version = Version{
        .major = 0,
        .minor = 0,
        .patch = 0,
        .prerelease = null,
        .build_metadata = null,
        .allocator = allocator,
    };
    errdefer version.deinit();

    var remaining = str;

    // Strip leading 'v' if present
    if (remaining.len > 0 and (remaining[0] == 'v' or remaining[0] == 'V')) {
        remaining = remaining[1..];
    }

    // Find build metadata
    if (std.mem.indexOf(u8, remaining, "+")) |plus_pos| {
        version.build_metadata = try allocator.dupe(u8, remaining[plus_pos + 1 ..]);
        remaining = remaining[0..plus_pos];
    }

    // Find prerelease
    if (std.mem.indexOf(u8, remaining, "-")) |dash_pos| {
        version.prerelease = try allocator.dupe(u8, remaining[dash_pos + 1 ..]);
        remaining = remaining[0..dash_pos];
    }

    // Parse major.minor.patch
    var parts = std.mem.splitScalar(u8, remaining, '.');

    version.major = std.fmt.parseInt(u32, parts.next() orelse return ParseError.InvalidMajor, 10) catch
        return ParseError.InvalidMajor;

    version.minor = std.fmt.parseInt(u32, parts.next() orelse return ParseError.InvalidMinor, 10) catch
        return ParseError.InvalidMinor;

    version.patch = std.fmt.parseInt(u32, parts.next() orelse return ParseError.InvalidPatch, 10) catch
        return ParseError.InvalidPatch;

    // Should have no more parts
    if (parts.next() != null) {
        return ParseError.InvalidVersion;
    }

    return version;
}

/// Version range for dependency constraints.
pub const Range = struct {
    constraints: []Constraint,
    allocator: Allocator,

    pub const Constraint = struct {
        op: Operator,
        version: Version,
    };

    pub const Operator = enum {
        eq, // =
        ne, // !=
        gt, // >
        gte, // >=
        lt, // <
        lte, // <=
        tilde, // ~  (allows patch updates)
        caret, // ^  (allows minor updates)
    };

    pub fn deinit(self: *Range) void {
        for (self.constraints) |*c| {
            var v = c.version;
            v.deinit();
        }
        self.allocator.free(self.constraints);
    }

    /// Check if a version satisfies this range.
    pub fn contains(self: *const Range, version: Version) bool {
        for (self.constraints) |constraint| {
            if (!satisfiesConstraint(version, constraint)) {
                return false;
            }
        }
        return true;
    }
};

fn satisfiesConstraint(version: Version, constraint: Range.Constraint) bool {
    const cmp = version.compare(constraint.version);

    return switch (constraint.op) {
        .eq => cmp == .eq,
        .ne => cmp != .eq,
        .gt => cmp == .gt,
        .gte => cmp == .gt or cmp == .eq,
        .lt => cmp == .lt,
        .lte => cmp == .lt or cmp == .eq,
        .tilde => {
            // ~1.2.3 allows >=1.2.3 <1.3.0
            if (version.major != constraint.version.major) return false;
            if (version.minor != constraint.version.minor) return false;
            return version.patch >= constraint.version.patch;
        },
        .caret => {
            // ^1.2.3 allows >=1.2.3 <2.0.0
            // ^0.2.3 allows >=0.2.3 <0.3.0
            // ^0.0.3 allows >=0.0.3 <0.0.4
            if (constraint.version.major != 0) {
                if (version.major != constraint.version.major) return false;
                return cmp == .gt or cmp == .eq;
            }
            if (constraint.version.minor != 0) {
                if (version.major != 0) return false;
                if (version.minor != constraint.version.minor) return false;
                return version.patch >= constraint.version.patch;
            }
            return version.eql(constraint.version);
        },
    };
}

/// Parse a version range string.
pub fn parseRange(allocator: Allocator, str: []const u8) !Range {
    var constraints = std.ArrayList(Range.Constraint).init(allocator);
    errdefer {
        for (constraints.items) |*c| {
            var v = c.version;
            v.deinit();
        }
        constraints.deinit();
    }

    // Split on spaces or commas
    var iter = std.mem.tokenizeAny(u8, str, " ,");

    while (iter.next()) |part| {
        const constraint = try parseConstraint(allocator, part);
        try constraints.append(constraint);
    }

    if (constraints.items.len == 0) {
        return ParseError.InvalidVersion;
    }

    return Range{
        .constraints = try constraints.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn parseConstraint(allocator: Allocator, str: []const u8) !Range.Constraint {
    var remaining = str;
    var op: Range.Operator = .eq;

    if (std.mem.startsWith(u8, remaining, ">=")) {
        op = .gte;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, "<=")) {
        op = .lte;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, "!=")) {
        op = .ne;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, ">")) {
        op = .gt;
        remaining = remaining[1..];
    } else if (std.mem.startsWith(u8, remaining, "<")) {
        op = .lt;
        remaining = remaining[1..];
    } else if (std.mem.startsWith(u8, remaining, "~")) {
        op = .tilde;
        remaining = remaining[1..];
    } else if (std.mem.startsWith(u8, remaining, "^")) {
        op = .caret;
        remaining = remaining[1..];
    } else if (std.mem.startsWith(u8, remaining, "=")) {
        op = .eq;
        remaining = remaining[1..];
    }

    const version = try parse(allocator, remaining);

    return Range.Constraint{
        .op = op,
        .version = version,
    };
}

/// Find the maximum version from a list.
pub fn maxVersion(versions: []const Version) ?Version {
    if (versions.len == 0) return null;

    var max = versions[0];
    for (versions[1..]) |v| {
        if (v.greaterThan(max)) {
            max = v;
        }
    }
    return max;
}

/// Find the minimum version from a list.
pub fn minVersion(versions: []const Version) ?Version {
    if (versions.len == 0) return null;

    var min = versions[0];
    for (versions[1..]) |v| {
        if (v.lessThan(min)) {
            min = v;
        }
    }
    return min;
}

/// Sort versions in ascending order.
pub fn sortVersions(versions: []Version) void {
    std.mem.sort(Version, versions, {}, struct {
        fn lessThan(_: void, a: Version, b: Version) bool {
            return a.lessThan(b);
        }
    }.lessThan);
}

test "parse simple version" {
    const allocator = std.testing.allocator;
    var v = try parse(allocator, "1.2.3");
    defer v.deinit();

    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
    try std.testing.expect(v.prerelease == null);
}

test "parse version with prerelease" {
    const allocator = std.testing.allocator;
    var v = try parse(allocator, "1.0.0-alpha.1");
    defer v.deinit();

    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqualStrings("alpha.1", v.prerelease.?);
}

test "version comparison" {
    const v1 = Version.init(1, 0, 0);
    const v2 = Version.init(2, 0, 0);
    const v3 = Version.init(1, 1, 0);

    try std.testing.expect(v1.lessThan(v2));
    try std.testing.expect(v1.lessThan(v3));
    try std.testing.expect(v2.greaterThan(v1));
}

test "prerelease comparison" {
    const allocator = std.testing.allocator;

    var alpha = try parse(allocator, "1.0.0-alpha");
    defer alpha.deinit();

    var beta = try parse(allocator, "1.0.0-beta");
    defer beta.deinit();

    var release = try parse(allocator, "1.0.0");
    defer release.deinit();

    try std.testing.expect(alpha.lessThan(beta));
    try std.testing.expect(beta.lessThan(release));
}

test "range matching" {
    const allocator = std.testing.allocator;

    var range = try parseRange(allocator, ">=1.0.0 <2.0.0");
    defer range.deinit();

    try std.testing.expect(range.contains(Version.init(1, 0, 0)));
    try std.testing.expect(range.contains(Version.init(1, 5, 0)));
    try std.testing.expect(!range.contains(Version.init(0, 9, 0)));
    try std.testing.expect(!range.contains(Version.init(2, 0, 0)));
}

test "caret range" {
    const allocator = std.testing.allocator;

    var range = try parseRange(allocator, "^1.2.3");
    defer range.deinit();

    try std.testing.expect(range.contains(Version.init(1, 2, 3)));
    try std.testing.expect(range.contains(Version.init(1, 9, 9)));
    try std.testing.expect(!range.contains(Version.init(2, 0, 0)));
}
