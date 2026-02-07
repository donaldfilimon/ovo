//! Glob pattern matching for ovo package manager.
//! Supports standard glob patterns: *, **, ?, [abc], [a-z], [!abc]

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error types for glob operations.
pub const GlobError = error{
    InvalidPattern,
    UnmatchedBracket,
    InvalidRange,
    OutOfMemory,
};

/// Compiled glob pattern for efficient repeated matching.
pub const Pattern = struct {
    segments: []Segment,
    allocator: Allocator,
    original: []const u8,

    const Segment = union(enum) {
        literal: []const u8,
        any_char, // ?
        any_sequence, // *
        recursive, // **
        char_class: CharClass,
    };

    const CharClass = struct {
        chars: []const u8,
        ranges: []const [2]u8,
        negated: bool,
    };

    pub fn deinit(self: *Pattern) void {
        for (self.segments) |seg| {
            switch (seg) {
                .literal => |lit| self.allocator.free(lit),
                .char_class => |cc| {
                    self.allocator.free(cc.chars);
                    self.allocator.free(cc.ranges);
                },
                else => {},
            }
        }
        self.allocator.free(self.segments);
        self.allocator.free(self.original);
    }

    /// Check if this pattern matches a string.
    pub fn match(self: *const Pattern, str: []const u8) bool {
        return matchSegments(self.segments, str);
    }

    /// Check if pattern matches any path component.
    pub fn matchPath(self: *const Pattern, path: []const u8) bool {
        // For ** patterns, need special handling
        var has_recursive = false;
        for (self.segments) |seg| {
            if (seg == .recursive) {
                has_recursive = true;
                break;
            }
        }

        if (has_recursive) {
            return matchRecursivePath(self.segments, path);
        }

        return self.match(path);
    }
};

/// Compile a glob pattern for repeated use.
pub fn compile(allocator: Allocator, pattern: []const u8) !Pattern {
    var segments: std.ArrayList(Pattern.Segment) = .empty;
    errdefer {
        for (segments.items) |seg| {
            switch (seg) {
                .literal => |lit| allocator.free(lit),
                .char_class => |cc| {
                    allocator.free(cc.chars);
                    allocator.free(cc.ranges);
                },
                else => {},
            }
        }
        segments.deinit(allocator);
    }

    var i: usize = 0;
    var literal_start: ?usize = null;

    while (i < pattern.len) {
        const c = pattern[i];

        switch (c) {
            '*' => {
                // Flush literal
                if (literal_start) |start| {
                    try segments.append(allocator, .{ .literal = try allocator.dupe(u8, pattern[start..i]) });
                    literal_start = null;
                }

                // Check for **
                if (i + 1 < pattern.len and pattern[i + 1] == '*') {
                    try segments.append(allocator, .recursive);
                    i += 2;
                    // Skip trailing / if present
                    if (i < pattern.len and (pattern[i] == '/' or pattern[i] == '\\')) {
                        i += 1;
                    }
                } else {
                    try segments.append(allocator, .any_sequence);
                    i += 1;
                }
            },
            '?' => {
                if (literal_start) |start| {
                    try segments.append(allocator, .{ .literal = try allocator.dupe(u8, pattern[start..i]) });
                    literal_start = null;
                }
                try segments.append(allocator, .any_char);
                i += 1;
            },
            '[' => {
                if (literal_start) |start| {
                    try segments.append(allocator, .{ .literal = try allocator.dupe(u8, pattern[start..i]) });
                    literal_start = null;
                }

                const cc = try parseCharClass(allocator, pattern[i..]);
                try segments.append(allocator, .{ .char_class = cc.class });
                i += cc.consumed;
            },
            '\\' => {
                // Escape next character
                if (i + 1 < pattern.len) {
                    if (literal_start == null) {
                        literal_start = i + 1;
                    }
                    i += 2;
                } else {
                    if (literal_start == null) {
                        literal_start = i;
                    }
                    i += 1;
                }
            },
            else => {
                if (literal_start == null) {
                    literal_start = i;
                }
                i += 1;
            },
        }
    }

    // Flush remaining literal
    if (literal_start) |start| {
        try segments.append(allocator, .{ .literal = try allocator.dupe(u8, pattern[start..]) });
    }

    return Pattern{
        .segments = try segments.toOwnedSlice(allocator),
        .allocator = allocator,
        .original = try allocator.dupe(u8, pattern),
    };
}

const CharClassResult = struct {
    class: Pattern.CharClass,
    consumed: usize,
};

fn parseCharClass(allocator: Allocator, pattern: []const u8) !CharClassResult {
    if (pattern.len == 0 or pattern[0] != '[') {
        return GlobError.InvalidPattern;
    }

    var chars: std.ArrayList(u8) = .empty;
    errdefer chars.deinit(allocator);
    var ranges: std.ArrayList([2]u8) = .empty;
    errdefer ranges.deinit(allocator);

    var i: usize = 1;
    var negated = false;

    // Check for negation
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negated = true;
        i += 1;
    }

    // Special case: ] as first char is literal
    if (i < pattern.len and pattern[i] == ']') {
        try chars.append(allocator, ']');
        i += 1;
    }

    while (i < pattern.len) {
        const c = pattern[i];

        if (c == ']') {
            return CharClassResult{
                .class = .{
                    .chars = try chars.toOwnedSlice(allocator),
                    .ranges = try ranges.toOwnedSlice(allocator),
                    .negated = negated,
                },
                .consumed = i + 1,
            };
        }

        // Check for range
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            const start = c;
            const end = pattern[i + 2];
            if (start > end) {
                return GlobError.InvalidRange;
            }
            try ranges.append(allocator, .{ start, end });
            i += 3;
        } else {
            try chars.append(allocator, c);
            i += 1;
        }
    }

    return GlobError.UnmatchedBracket;
}

fn matchSegments(segments: []const Pattern.Segment, str: []const u8) bool {
    return matchSegmentsRecursive(segments, str, 0, 0);
}

fn matchSegmentsRecursive(
    segments: []const Pattern.Segment,
    str: []const u8,
    seg_idx: usize,
    str_idx: usize,
) bool {
    var si = seg_idx;
    var ci = str_idx;

    while (si < segments.len) {
        const seg = segments[si];

        switch (seg) {
            .literal => |lit| {
                if (ci + lit.len > str.len) return false;
                if (!std.mem.eql(u8, str[ci .. ci + lit.len], lit)) return false;
                ci += lit.len;
                si += 1;
            },
            .any_char => {
                if (ci >= str.len) return false;
                // Don't match path separators
                if (str[ci] == '/' or str[ci] == '\\') return false;
                ci += 1;
                si += 1;
            },
            .any_sequence => {
                // Try matching 0 or more characters (not crossing path separators)
                var try_len: usize = 0;
                while (ci + try_len <= str.len) {
                    // Don't cross path separators
                    if (try_len > 0 and (str[ci + try_len - 1] == '/' or str[ci + try_len - 1] == '\\')) {
                        break;
                    }

                    if (matchSegmentsRecursive(segments, str, si + 1, ci + try_len)) {
                        return true;
                    }
                    try_len += 1;

                    if (ci + try_len > str.len) break;
                }
                return false;
            },
            .recursive => {
                // ** matches zero or more path components
                var try_pos = ci;
                while (try_pos <= str.len) {
                    if (matchSegmentsRecursive(segments, str, si + 1, try_pos)) {
                        return true;
                    }
                    if (try_pos >= str.len) break;
                    try_pos += 1;
                }
                return false;
            },
            .char_class => |cc| {
                if (ci >= str.len) return false;
                const ch = str[ci];

                var in_class = false;
                for (cc.chars) |class_char| {
                    if (ch == class_char) {
                        in_class = true;
                        break;
                    }
                }
                if (!in_class) {
                    for (cc.ranges) |range| {
                        if (ch >= range[0] and ch <= range[1]) {
                            in_class = true;
                            break;
                        }
                    }
                }

                if (cc.negated) in_class = !in_class;
                if (!in_class) return false;

                ci += 1;
                si += 1;
            },
        }
    }

    return ci == str.len;
}

fn matchRecursivePath(segments: []const Pattern.Segment, path: []const u8) bool {
    return matchSegmentsRecursive(segments, path, 0, 0);
}

/// Simple pattern matching without compilation (for one-off use).
pub fn match(pattern: []const u8, str: []const u8) bool {
    return matchSimple(pattern, str, 0, 0);
}

fn matchSimple(pattern: []const u8, str: []const u8, p_idx: usize, s_idx: usize) bool {
    var pi = p_idx;
    var si = s_idx;

    while (pi < pattern.len) {
        if (si < str.len and pattern[pi] == '\\' and pi + 1 < pattern.len) {
            // Escaped character
            pi += 1;
            if (pattern[pi] != str[si]) return false;
            pi += 1;
            si += 1;
        } else if (pattern[pi] == '*') {
            // Check for **
            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                pi += 2;
                // Skip path separator after **
                if (pi < pattern.len and (pattern[pi] == '/' or pattern[pi] == '\\')) {
                    pi += 1;
                }
                // Try matching at every position
                while (si <= str.len) {
                    if (matchSimple(pattern, str, pi, si)) return true;
                    if (si >= str.len) break;
                    si += 1;
                }
                return false;
            } else {
                // Single * - doesn't cross path separators
                pi += 1;
                while (si <= str.len) {
                    if (matchSimple(pattern, str, pi, si)) return true;
                    if (si >= str.len) break;
                    if (str[si] == '/' or str[si] == '\\') break;
                    si += 1;
                }
                return false;
            }
        } else if (pattern[pi] == '?') {
            if (si >= str.len) return false;
            if (str[si] == '/' or str[si] == '\\') return false;
            pi += 1;
            si += 1;
        } else if (pattern[pi] == '[') {
            if (si >= str.len) return false;
            const result = matchCharClass(pattern[pi..], str[si]);
            if (!result.matched) return false;
            pi += result.consumed;
            si += 1;
        } else {
            if (si >= str.len) return false;
            if (pattern[pi] != str[si]) return false;
            pi += 1;
            si += 1;
        }
    }

    return si == str.len;
}

const CharClassMatch = struct {
    matched: bool,
    consumed: usize,
};

fn matchCharClass(pattern: []const u8, c: u8) CharClassMatch {
    if (pattern.len == 0 or pattern[0] != '[') {
        return .{ .matched = false, .consumed = 0 };
    }

    var i: usize = 1;
    var negated = false;
    var matched = false;

    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negated = true;
        i += 1;
    }

    // ] as first char
    if (i < pattern.len and pattern[i] == ']') {
        if (c == ']') matched = true;
        i += 1;
    }

    while (i < pattern.len and pattern[i] != ']') {
        // Check range
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (c >= pattern[i] and c <= pattern[i + 2]) {
                matched = true;
            }
            i += 3;
        } else {
            if (c == pattern[i]) matched = true;
            i += 1;
        }
    }

    if (i < pattern.len and pattern[i] == ']') {
        i += 1;
    }

    if (negated) matched = !matched;

    return .{ .matched = matched, .consumed = i };
}

/// Check if a pattern matches a file path, handling path separators correctly.
pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    // Normalize path separators for matching
    return match(pattern, path);
}

/// Filter a list of paths by a glob pattern.
pub fn filter(
    allocator: Allocator,
    paths: []const []const u8,
    pattern: []const u8,
) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer results.deinit(allocator);

    for (paths) |path| {
        if (match(pattern, path)) {
            try results.append(allocator, path);
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Check if a string contains glob metacharacters.
pub fn isGlobPattern(str: []const u8) bool {
    for (str) |c| {
        switch (c) {
            '*', '?', '[', ']' => return true,
            '\\' => continue, // Escape
            else => {},
        }
    }
    return false;
}

test "simple glob matching" {
    try std.testing.expect(match("*.zig", "test.zig"));
    try std.testing.expect(match("test.*", "test.zig"));
    try std.testing.expect(match("t?st.zig", "test.zig"));
    try std.testing.expect(!match("*.cpp", "test.zig"));
    try std.testing.expect(match("*", "anything"));
}

test "character class matching" {
    try std.testing.expect(match("[abc]", "a"));
    try std.testing.expect(match("[abc]", "b"));
    try std.testing.expect(!match("[abc]", "d"));
    try std.testing.expect(match("[a-z]", "m"));
    try std.testing.expect(!match("[a-z]", "M"));
    try std.testing.expect(match("[!abc]", "d"));
    try std.testing.expect(!match("[!abc]", "a"));
}

test "recursive glob matching" {
    try std.testing.expect(match("**/*.zig", "src/util/test.zig"));
    try std.testing.expect(match("src/**/test.zig", "src/util/test.zig"));
    try std.testing.expect(match("**/test.zig", "test.zig"));
}

test "compiled pattern" {
    const allocator = std.testing.allocator;
    var pat = try compile(allocator, "*.zig");
    defer pat.deinit();

    try std.testing.expect(pat.match("test.zig"));
    try std.testing.expect(!pat.match("test.cpp"));
}
