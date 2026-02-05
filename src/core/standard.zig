//! C and C++ language standard definitions with compiler flag mappings.
//!
//! This module provides strongly-typed representations of C and C++ language
//! standards (C99 through C23, C++11 through C++26) along with mappings to
//! the corresponding compiler flags for GCC, Clang, and MSVC.
//!
//! ## Example
//! ```zig
//! const std_ver = CppStandard.cpp20;
//! const flags = std_ver.compilerFlags(.gcc);
//! // flags contains ["-std=c++20"]
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// C language standard versions.
/// Represents the various ISO C standards from C99 onwards.
pub const CStandard = enum {
    /// ISO C99 (ISO/IEC 9899:1999)
    c99,
    /// ISO C11 (ISO/IEC 9899:2011)
    c11,
    /// ISO C17/C18 (ISO/IEC 9899:2018)
    c17,
    /// ISO C23 (ISO/IEC 9899:2024)
    c23,
    /// GNU extensions to C99
    gnu99,
    /// GNU extensions to C11
    gnu11,
    /// GNU extensions to C17
    gnu17,
    /// GNU extensions to C23
    gnu23,

    const Self = @This();

    /// Returns the compiler flag for the given compiler.
    /// Returns null for unsupported compiler/standard combinations.
    pub fn compilerFlag(self: Self, compiler: Compiler) ?[]const u8 {
        return switch (compiler) {
            .gcc, .clang => switch (self) {
                .c99 => "-std=c99",
                .c11 => "-std=c11",
                .c17 => "-std=c17",
                .c23 => "-std=c23",
                .gnu99 => "-std=gnu99",
                .gnu11 => "-std=gnu11",
                .gnu17 => "-std=gnu17",
                .gnu23 => "-std=gnu23",
            },
            .msvc => switch (self) {
                .c11 => "/std:c11",
                .c17 => "/std:c17",
                // MSVC doesn't support C99 as a separate mode or C23 yet
                // and doesn't support GNU extensions
                else => null,
            },
            .unknown => null,
        };
    }

    /// Returns the year this standard was published.
    pub fn year(self: Self) u16 {
        return switch (self) {
            .c99, .gnu99 => 1999,
            .c11, .gnu11 => 2011,
            .c17, .gnu17 => 2017,
            .c23, .gnu23 => 2023,
        };
    }

    /// Returns true if this is a GNU extension standard.
    pub fn isGnuExtension(self: Self) bool {
        return switch (self) {
            .gnu99, .gnu11, .gnu17, .gnu23 => true,
            else => false,
        };
    }

    /// Returns the base ISO standard (without GNU extensions).
    pub fn baseStandard(self: Self) Self {
        return switch (self) {
            .gnu99 => .c99,
            .gnu11 => .c11,
            .gnu17 => .c17,
            .gnu23 => .c23,
            else => self,
        };
    }

    /// Parses a string representation of a C standard.
    /// Accepts formats like "c99", "c11", "gnu17", "C23", etc.
    pub fn parse(str: []const u8) ParseError!Self {
        const lower = blk: {
            var buf: [8]u8 = undefined;
            if (str.len > buf.len) return ParseError.InvalidStandard;
            for (str, 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..str.len];
        };

        if (std.mem.eql(u8, lower, "c99")) return .c99;
        if (std.mem.eql(u8, lower, "c11")) return .c11;
        if (std.mem.eql(u8, lower, "c17") or std.mem.eql(u8, lower, "c18")) return .c17;
        if (std.mem.eql(u8, lower, "c23")) return .c23;
        if (std.mem.eql(u8, lower, "gnu99")) return .gnu99;
        if (std.mem.eql(u8, lower, "gnu11")) return .gnu11;
        if (std.mem.eql(u8, lower, "gnu17") or std.mem.eql(u8, lower, "gnu18")) return .gnu17;
        if (std.mem.eql(u8, lower, "gnu23")) return .gnu23;

        return ParseError.InvalidStandard;
    }

    /// Formats the standard as a string (e.g., "c99", "gnu17").
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const str = switch (self) {
            .c99 => "c99",
            .c11 => "c11",
            .c17 => "c17",
            .c23 => "c23",
            .gnu99 => "gnu99",
            .gnu11 => "gnu11",
            .gnu17 => "gnu17",
            .gnu23 => "gnu23",
        };
        try writer.writeAll(str);
    }
};

/// C++ language standard versions.
/// Represents the various ISO C++ standards from C++11 onwards.
pub const CppStandard = enum {
    /// ISO C++11 (ISO/IEC 14882:2011)
    cpp11,
    /// ISO C++14 (ISO/IEC 14882:2014)
    cpp14,
    /// ISO C++17 (ISO/IEC 14882:2017)
    cpp17,
    /// ISO C++20 (ISO/IEC 14882:2020)
    cpp20,
    /// ISO C++23 (ISO/IEC 14882:2023)
    cpp23,
    /// ISO C++26 (upcoming)
    cpp26,
    /// GNU extensions to C++11
    gnucpp11,
    /// GNU extensions to C++14
    gnucpp14,
    /// GNU extensions to C++17
    gnucpp17,
    /// GNU extensions to C++20
    gnucpp20,
    /// GNU extensions to C++23
    gnucpp23,
    /// GNU extensions to C++26
    gnucpp26,

    const Self = @This();

    /// Returns the compiler flag for the given compiler.
    /// Returns null for unsupported compiler/standard combinations.
    pub fn compilerFlag(self: Self, compiler: Compiler) ?[]const u8 {
        return switch (compiler) {
            .gcc, .clang => switch (self) {
                .cpp11 => "-std=c++11",
                .cpp14 => "-std=c++14",
                .cpp17 => "-std=c++17",
                .cpp20 => "-std=c++20",
                .cpp23 => "-std=c++23",
                .cpp26 => "-std=c++26",
                .gnucpp11 => "-std=gnu++11",
                .gnucpp14 => "-std=gnu++14",
                .gnucpp17 => "-std=gnu++17",
                .gnucpp20 => "-std=gnu++20",
                .gnucpp23 => "-std=gnu++23",
                .gnucpp26 => "-std=gnu++26",
            },
            .msvc => switch (self) {
                .cpp14 => "/std:c++14",
                .cpp17 => "/std:c++17",
                .cpp20 => "/std:c++20",
                .cpp23 => "/std:c++latest",
                // MSVC doesn't have separate C++11 mode and doesn't support GNU extensions
                else => null,
            },
            .unknown => null,
        };
    }

    /// Returns the year this standard was published (or expected).
    pub fn year(self: Self) u16 {
        return switch (self) {
            .cpp11, .gnucpp11 => 2011,
            .cpp14, .gnucpp14 => 2014,
            .cpp17, .gnucpp17 => 2017,
            .cpp20, .gnucpp20 => 2020,
            .cpp23, .gnucpp23 => 2023,
            .cpp26, .gnucpp26 => 2026,
        };
    }

    /// Returns true if this is a GNU extension standard.
    pub fn isGnuExtension(self: Self) bool {
        return switch (self) {
            .gnucpp11, .gnucpp14, .gnucpp17, .gnucpp20, .gnucpp23, .gnucpp26 => true,
            else => false,
        };
    }

    /// Returns the base ISO standard (without GNU extensions).
    pub fn baseStandard(self: Self) Self {
        return switch (self) {
            .gnucpp11 => .cpp11,
            .gnucpp14 => .cpp14,
            .gnucpp17 => .cpp17,
            .gnucpp20 => .cpp20,
            .gnucpp23 => .cpp23,
            .gnucpp26 => .cpp26,
            else => self,
        };
    }

    /// Parses a string representation of a C++ standard.
    /// Accepts formats like "c++17", "cpp20", "gnu++23", "C++11", etc.
    pub fn parse(str: []const u8) ParseError!Self {
        const lower = blk: {
            var buf: [16]u8 = undefined;
            if (str.len > buf.len) return ParseError.InvalidStandard;
            for (str, 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..str.len];
        };

        // Handle both "c++XX" and "cppXX" formats
        if (std.mem.eql(u8, lower, "c++11") or std.mem.eql(u8, lower, "cpp11")) return .cpp11;
        if (std.mem.eql(u8, lower, "c++14") or std.mem.eql(u8, lower, "cpp14")) return .cpp14;
        if (std.mem.eql(u8, lower, "c++17") or std.mem.eql(u8, lower, "cpp17")) return .cpp17;
        if (std.mem.eql(u8, lower, "c++20") or std.mem.eql(u8, lower, "cpp20")) return .cpp20;
        if (std.mem.eql(u8, lower, "c++23") or std.mem.eql(u8, lower, "cpp23")) return .cpp23;
        if (std.mem.eql(u8, lower, "c++26") or std.mem.eql(u8, lower, "cpp26")) return .cpp26;

        // GNU extensions
        if (std.mem.eql(u8, lower, "gnu++11") or std.mem.eql(u8, lower, "gnucpp11")) return .gnucpp11;
        if (std.mem.eql(u8, lower, "gnu++14") or std.mem.eql(u8, lower, "gnucpp14")) return .gnucpp14;
        if (std.mem.eql(u8, lower, "gnu++17") or std.mem.eql(u8, lower, "gnucpp17")) return .gnucpp17;
        if (std.mem.eql(u8, lower, "gnu++20") or std.mem.eql(u8, lower, "gnucpp20")) return .gnucpp20;
        if (std.mem.eql(u8, lower, "gnu++23") or std.mem.eql(u8, lower, "gnucpp23")) return .gnucpp23;
        if (std.mem.eql(u8, lower, "gnu++26") or std.mem.eql(u8, lower, "gnucpp26")) return .gnucpp26;

        return ParseError.InvalidStandard;
    }

    /// Formats the standard as a string (e.g., "c++17", "gnu++20").
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const str = switch (self) {
            .cpp11 => "c++11",
            .cpp14 => "c++14",
            .cpp17 => "c++17",
            .cpp20 => "c++20",
            .cpp23 => "c++23",
            .cpp26 => "c++26",
            .gnucpp11 => "gnu++11",
            .gnucpp14 => "gnu++14",
            .gnucpp17 => "gnu++17",
            .gnucpp20 => "gnu++20",
            .gnucpp23 => "gnu++23",
            .gnucpp26 => "gnu++26",
        };
        try writer.writeAll(str);
    }
};

/// Supported compiler toolchains.
pub const Compiler = enum {
    /// GNU Compiler Collection (gcc/g++)
    gcc,
    /// LLVM Clang (clang/clang++)
    clang,
    /// Microsoft Visual C++ (cl.exe)
    msvc,
    /// Unknown or unsupported compiler
    unknown,

    const Self = @This();

    /// Detects the compiler from an executable name.
    pub fn fromExecutable(name: []const u8) Self {
        // Extract basename without extension
        const basename = std.fs.path.basename(name);
        const stem = blk: {
            if (std.mem.lastIndexOf(u8, basename, ".")) |dot| {
                break :blk basename[0..dot];
            }
            break :blk basename;
        };

        if (std.mem.indexOf(u8, stem, "clang") != null) return .clang;
        if (std.mem.indexOf(u8, stem, "gcc") != null or std.mem.indexOf(u8, stem, "g++") != null) return .gcc;
        if (std.mem.eql(u8, stem, "cl")) return .msvc;

        return .unknown;
    }

    /// Returns the default C compiler executable name.
    pub fn defaultCCompiler(self: Self) []const u8 {
        return switch (self) {
            .gcc => "gcc",
            .clang => "clang",
            .msvc => "cl.exe",
            .unknown => "cc",
        };
    }

    /// Returns the default C++ compiler executable name.
    pub fn defaultCppCompiler(self: Self) []const u8 {
        return switch (self) {
            .gcc => "g++",
            .clang => "clang++",
            .msvc => "cl.exe",
            .unknown => "c++",
        };
    }
};

/// A combined language standard that can be either C or C++.
pub const LanguageStandard = union(enum) {
    c: CStandard,
    cpp: CppStandard,

    const Self = @This();

    /// Returns the compiler flag for the given compiler.
    pub fn compilerFlag(self: Self, compiler: Compiler) ?[]const u8 {
        return switch (self) {
            .c => |c| c.compilerFlag(compiler),
            .cpp => |cpp| cpp.compilerFlag(compiler),
        };
    }

    /// Returns the year this standard was published.
    pub fn year(self: Self) u16 {
        return switch (self) {
            .c => |c| c.year(),
            .cpp => |cpp| cpp.year(),
        };
    }

    /// Parses a string that could be either a C or C++ standard.
    /// Tries C++ first since it's more specific (contains "++").
    pub fn parse(str: []const u8) ParseError!Self {
        // Try C++ first (more specific patterns)
        if (CppStandard.parse(str)) |cpp| {
            return .{ .cpp = cpp };
        } else |_| {}

        // Fall back to C
        if (CStandard.parse(str)) |c| {
            return .{ .c = c };
        } else |err| {
            return err;
        }
    }
};

/// Errors that can occur when parsing standard strings.
pub const ParseError = error{
    /// The provided string does not match any known standard.
    InvalidStandard,
};

// ============================================================================
// Tests
// ============================================================================

test "CStandard.compilerFlag" {
    // GCC/Clang flags
    try testing.expectEqualStrings("-std=c99", CStandard.c99.compilerFlag(.gcc).?);
    try testing.expectEqualStrings("-std=c11", CStandard.c11.compilerFlag(.clang).?);
    try testing.expectEqualStrings("-std=gnu17", CStandard.gnu17.compilerFlag(.gcc).?);

    // MSVC flags
    try testing.expectEqualStrings("/std:c11", CStandard.c11.compilerFlag(.msvc).?);
    try testing.expectEqualStrings("/std:c17", CStandard.c17.compilerFlag(.msvc).?);
    try testing.expect(CStandard.c99.compilerFlag(.msvc) == null);
    try testing.expect(CStandard.gnu11.compilerFlag(.msvc) == null);
}

test "CppStandard.compilerFlag" {
    // GCC/Clang flags
    try testing.expectEqualStrings("-std=c++17", CppStandard.cpp17.compilerFlag(.gcc).?);
    try testing.expectEqualStrings("-std=c++20", CppStandard.cpp20.compilerFlag(.clang).?);
    try testing.expectEqualStrings("-std=gnu++23", CppStandard.gnucpp23.compilerFlag(.gcc).?);

    // MSVC flags
    try testing.expectEqualStrings("/std:c++17", CppStandard.cpp17.compilerFlag(.msvc).?);
    try testing.expectEqualStrings("/std:c++20", CppStandard.cpp20.compilerFlag(.msvc).?);
    try testing.expect(CppStandard.cpp11.compilerFlag(.msvc) == null);
    try testing.expect(CppStandard.gnucpp20.compilerFlag(.msvc) == null);
}

test "CStandard.parse" {
    try testing.expectEqual(CStandard.c99, try CStandard.parse("c99"));
    try testing.expectEqual(CStandard.c11, try CStandard.parse("C11"));
    try testing.expectEqual(CStandard.c17, try CStandard.parse("c17"));
    try testing.expectEqual(CStandard.c17, try CStandard.parse("c18"));
    try testing.expectEqual(CStandard.gnu17, try CStandard.parse("gnu17"));
    try testing.expectError(ParseError.InvalidStandard, CStandard.parse("c++17"));
    try testing.expectError(ParseError.InvalidStandard, CStandard.parse("invalid"));
}

test "CppStandard.parse" {
    try testing.expectEqual(CppStandard.cpp11, try CppStandard.parse("c++11"));
    try testing.expectEqual(CppStandard.cpp17, try CppStandard.parse("cpp17"));
    try testing.expectEqual(CppStandard.cpp20, try CppStandard.parse("C++20"));
    try testing.expectEqual(CppStandard.gnucpp23, try CppStandard.parse("gnu++23"));
    try testing.expectError(ParseError.InvalidStandard, CppStandard.parse("c99"));
    try testing.expectError(ParseError.InvalidStandard, CppStandard.parse("invalid"));
}

test "CStandard.isGnuExtension" {
    try testing.expect(!CStandard.c99.isGnuExtension());
    try testing.expect(!CStandard.c17.isGnuExtension());
    try testing.expect(CStandard.gnu99.isGnuExtension());
    try testing.expect(CStandard.gnu17.isGnuExtension());
}

test "CppStandard.isGnuExtension" {
    try testing.expect(!CppStandard.cpp17.isGnuExtension());
    try testing.expect(!CppStandard.cpp20.isGnuExtension());
    try testing.expect(CppStandard.gnucpp17.isGnuExtension());
    try testing.expect(CppStandard.gnucpp20.isGnuExtension());
}

test "CStandard.baseStandard" {
    try testing.expectEqual(CStandard.c99, CStandard.gnu99.baseStandard());
    try testing.expectEqual(CStandard.c17, CStandard.c17.baseStandard());
}

test "CppStandard.baseStandard" {
    try testing.expectEqual(CppStandard.cpp20, CppStandard.gnucpp20.baseStandard());
    try testing.expectEqual(CppStandard.cpp17, CppStandard.cpp17.baseStandard());
}

test "CStandard.year" {
    try testing.expectEqual(@as(u16, 1999), CStandard.c99.year());
    try testing.expectEqual(@as(u16, 2011), CStandard.c11.year());
    try testing.expectEqual(@as(u16, 2017), CStandard.gnu17.year());
    try testing.expectEqual(@as(u16, 2023), CStandard.c23.year());
}

test "CppStandard.year" {
    try testing.expectEqual(@as(u16, 2011), CppStandard.cpp11.year());
    try testing.expectEqual(@as(u16, 2017), CppStandard.cpp17.year());
    try testing.expectEqual(@as(u16, 2020), CppStandard.gnucpp20.year());
    try testing.expectEqual(@as(u16, 2026), CppStandard.cpp26.year());
}

test "Compiler.fromExecutable" {
    try testing.expectEqual(Compiler.gcc, Compiler.fromExecutable("gcc"));
    try testing.expectEqual(Compiler.gcc, Compiler.fromExecutable("g++"));
    try testing.expectEqual(Compiler.gcc, Compiler.fromExecutable("/usr/bin/gcc-12"));
    try testing.expectEqual(Compiler.clang, Compiler.fromExecutable("clang"));
    try testing.expectEqual(Compiler.clang, Compiler.fromExecutable("clang++"));
    try testing.expectEqual(Compiler.clang, Compiler.fromExecutable("/opt/llvm/bin/clang-15"));
    try testing.expectEqual(Compiler.msvc, Compiler.fromExecutable("cl"));
    try testing.expectEqual(Compiler.msvc, Compiler.fromExecutable("cl.exe"));
    try testing.expectEqual(Compiler.unknown, Compiler.fromExecutable("unknown-compiler"));
}

test "LanguageStandard.parse" {
    const cpp17 = try LanguageStandard.parse("c++17");
    try testing.expectEqual(CppStandard.cpp17, cpp17.cpp);

    const c11 = try LanguageStandard.parse("c11");
    try testing.expectEqual(CStandard.c11, c11.c);
}

test "CStandard format" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try CStandard.c17.format("", .{}, fbs.writer());
    try testing.expectEqualStrings("c17", fbs.getWritten());
}

test "CppStandard format" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try CppStandard.gnucpp20.format("", .{}, fbs.writer());
    try testing.expectEqualStrings("gnu++20", fbs.getWritten());
}
