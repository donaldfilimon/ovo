//! Platform detection and target triplet handling.
//!
//! This module provides types and utilities for working with target platforms,
//! including operating systems, CPU architectures, and complete target triplets.
//! Supports native platform detection and cross-compilation target specification.
//!
//! ## Target Triplet Format
//! Target triplets follow the format: `<arch>-<vendor>-<os>[-<abi>]`
//! Examples:
//! - `x86_64-unknown-linux-gnu`
//! - `aarch64-apple-macos`
//! - `x86_64-pc-windows-msvc`
//!
//! ## Example
//! ```zig
//! const native = Platform.detect();
//! const cross = try Platform.parse("aarch64-unknown-linux-gnu");
//! const triplet = cross.triplet();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// CPU architecture.
pub const Arch = enum {
    x86,
    x86_64,
    arm,
    aarch64,
    riscv32,
    riscv64,
    wasm32,
    wasm64,
    mips,
    mips64,
    powerpc,
    powerpc64,
    sparc,
    sparc64,
    unknown,

    const Self = @This();

    /// Detects the architecture at compile time.
    pub fn detect() Self {
        return fromBuiltin(builtin.cpu.arch);
    }

    /// Converts from std.Target.Cpu.Arch.
    pub fn fromBuiltin(arch: std.Target.Cpu.Arch) Self {
        return switch (arch) {
            .x86 => .x86,
            .x86_64 => .x86_64,
            .arm => .arm,
            .aarch64 => .aarch64,
            .riscv32 => .riscv32,
            .riscv64 => .riscv64,
            .wasm32 => .wasm32,
            .wasm64 => .wasm64,
            .mips => .mips,
            .mips64 => .mips64,
            .powerpc => .powerpc,
            .powerpc64 => .powerpc64,
            .sparc => .sparc,
            .sparc64 => .sparc64,
            else => .unknown,
        };
    }

    /// Parses an architecture string.
    pub fn parse(str: []const u8) ParseError!Self {
        if (std.mem.eql(u8, str, "x86") or std.mem.eql(u8, str, "i386") or std.mem.eql(u8, str, "i686")) return .x86;
        if (std.mem.eql(u8, str, "x86_64") or std.mem.eql(u8, str, "amd64")) return .x86_64;
        if (std.mem.eql(u8, str, "arm") or std.mem.eql(u8, str, "armv7")) return .arm;
        if (std.mem.eql(u8, str, "aarch64") or std.mem.eql(u8, str, "arm64")) return .aarch64;
        if (std.mem.eql(u8, str, "riscv32")) return .riscv32;
        if (std.mem.eql(u8, str, "riscv64")) return .riscv64;
        if (std.mem.eql(u8, str, "wasm32")) return .wasm32;
        if (std.mem.eql(u8, str, "wasm64")) return .wasm64;
        if (std.mem.eql(u8, str, "mips")) return .mips;
        if (std.mem.eql(u8, str, "mips64")) return .mips64;
        if (std.mem.eql(u8, str, "powerpc") or std.mem.eql(u8, str, "ppc")) return .powerpc;
        if (std.mem.eql(u8, str, "powerpc64") or std.mem.eql(u8, str, "ppc64")) return .powerpc64;
        if (std.mem.eql(u8, str, "sparc")) return .sparc;
        if (std.mem.eql(u8, str, "sparc64")) return .sparc64;
        return ParseError.InvalidArch;
    }

    /// Returns the string representation of this architecture.
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .x86 => "x86",
            .x86_64 => "x86_64",
            .arm => "arm",
            .aarch64 => "aarch64",
            .riscv32 => "riscv32",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
            .wasm64 => "wasm64",
            .mips => "mips",
            .mips64 => "mips64",
            .powerpc => "powerpc",
            .powerpc64 => "powerpc64",
            .sparc => "sparc",
            .sparc64 => "sparc64",
            .unknown => "unknown",
        };
    }

    /// Returns the pointer size in bits for this architecture.
    pub fn pointerBits(self: Self) u8 {
        return switch (self) {
            .x86, .arm, .riscv32, .wasm32, .mips, .powerpc, .sparc => 32,
            .x86_64, .aarch64, .riscv64, .wasm64, .mips64, .powerpc64, .sparc64 => 64,
            .unknown => 0,
        };
    }

    /// Returns true if this is a 64-bit architecture.
    pub fn is64Bit(self: Self) bool {
        return self.pointerBits() == 64;
    }
};

/// Operating system.
pub const Os = enum {
    linux,
    macos,
    windows,
    freebsd,
    openbsd,
    netbsd,
    ios,
    android,
    freestanding,
    wasi,
    unknown,

    const Self = @This();

    /// Detects the operating system at compile time.
    pub fn detect() Self {
        return fromBuiltin(builtin.os.tag);
    }

    /// Converts from std.Target.Os.Tag.
    pub fn fromBuiltin(os: std.Target.Os.Tag) Self {
        return switch (os) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            .freebsd => .freebsd,
            .openbsd => .openbsd,
            .netbsd => .netbsd,
            .ios => .ios,
            .freestanding => .freestanding,
            .wasi => .wasi,
            else => .unknown,
        };
    }

    /// Parses an operating system string.
    pub fn parse(str: []const u8) ParseError!Self {
        if (std.mem.eql(u8, str, "linux")) return .linux;
        if (std.mem.eql(u8, str, "macos") or std.mem.eql(u8, str, "darwin") or std.mem.eql(u8, str, "macosx")) return .macos;
        if (std.mem.eql(u8, str, "windows") or std.mem.eql(u8, str, "win32")) return .windows;
        if (std.mem.eql(u8, str, "freebsd")) return .freebsd;
        if (std.mem.eql(u8, str, "openbsd")) return .openbsd;
        if (std.mem.eql(u8, str, "netbsd")) return .netbsd;
        if (std.mem.eql(u8, str, "ios")) return .ios;
        if (std.mem.eql(u8, str, "android")) return .android;
        if (std.mem.eql(u8, str, "freestanding") or std.mem.eql(u8, str, "none")) return .freestanding;
        if (std.mem.eql(u8, str, "wasi")) return .wasi;
        return ParseError.InvalidOs;
    }

    /// Returns the string representation of this OS.
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            .freebsd => "freebsd",
            .openbsd => "openbsd",
            .netbsd => "netbsd",
            .ios => "ios",
            .android => "android",
            .freestanding => "freestanding",
            .wasi => "wasi",
            .unknown => "unknown",
        };
    }

    /// Returns true if this is a Unix-like operating system.
    pub fn isUnixLike(self: Self) bool {
        return switch (self) {
            .linux, .macos, .freebsd, .openbsd, .netbsd, .ios, .android => true,
            else => false,
        };
    }

    /// Returns true if this is an Apple operating system.
    pub fn isApple(self: Self) bool {
        return switch (self) {
            .macos, .ios => true,
            else => false,
        };
    }

    /// Returns the default executable extension for this OS.
    pub fn exeExtension(self: Self) []const u8 {
        return switch (self) {
            .windows => ".exe",
            .wasi => ".wasm",
            else => "",
        };
    }

    /// Returns the default shared library extension for this OS.
    pub fn sharedLibExtension(self: Self) []const u8 {
        return switch (self) {
            .windows => ".dll",
            .macos, .ios => ".dylib",
            else => ".so",
        };
    }

    /// Returns the default static library extension for this OS.
    pub fn staticLibExtension(self: Self) []const u8 {
        return switch (self) {
            .windows => ".lib",
            else => ".a",
        };
    }
};

/// Application Binary Interface.
pub const Abi = enum {
    gnu,
    musl,
    msvc,
    eabi,
    eabihf,
    android,
    none,
    unknown,

    const Self = @This();

    /// Parses an ABI string.
    pub fn parse(str: []const u8) ParseError!Self {
        if (std.mem.eql(u8, str, "gnu")) return .gnu;
        if (std.mem.eql(u8, str, "musl")) return .musl;
        if (std.mem.eql(u8, str, "msvc")) return .msvc;
        if (std.mem.eql(u8, str, "eabi")) return .eabi;
        if (std.mem.eql(u8, str, "eabihf")) return .eabihf;
        if (std.mem.eql(u8, str, "android") or std.mem.eql(u8, str, "androideabi")) return .android;
        if (std.mem.eql(u8, str, "none")) return .none;
        return ParseError.InvalidAbi;
    }

    /// Returns the string representation of this ABI.
    pub fn toString(self: Self) ?[]const u8 {
        return switch (self) {
            .gnu => "gnu",
            .musl => "musl",
            .msvc => "msvc",
            .eabi => "eabi",
            .eabihf => "eabihf",
            .android => "android",
            .none, .unknown => null,
        };
    }
};

/// Vendor/manufacturer identifier.
pub const Vendor = enum {
    unknown,
    apple,
    pc,
    nvidia,

    const Self = @This();

    /// Parses a vendor string.
    pub fn parse(str: []const u8) Self {
        if (std.mem.eql(u8, str, "apple")) return .apple;
        if (std.mem.eql(u8, str, "pc")) return .pc;
        if (std.mem.eql(u8, str, "nvidia")) return .nvidia;
        if (std.mem.eql(u8, str, "unknown")) return .unknown;
        return .unknown;
    }

    /// Returns the string representation of this vendor.
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .apple => "apple",
            .pc => "pc",
            .nvidia => "nvidia",
        };
    }
};

/// Complete platform specification (target triplet).
pub const Platform = struct {
    arch: Arch,
    vendor: Vendor,
    os: Os,
    abi: Abi,

    const Self = @This();

    /// Detects the native platform at compile time.
    pub fn detect() Self {
        const arch = Arch.detect();
        const os = Os.detect();
        const vendor: Vendor = if (os.isApple()) .apple else if (os == .windows) .pc else .unknown;
        const abi: Abi = if (os == .windows) .msvc else if (os == .linux) .gnu else .none;

        return .{
            .arch = arch,
            .vendor = vendor,
            .os = os,
            .abi = abi,
        };
    }

    /// Parses a target triplet string.
    /// Format: `<arch>-<vendor>-<os>[-<abi>]`
    pub fn parse(triplet_str: []const u8) ParseError!Self {
        var iter = std.mem.splitScalar(u8, triplet_str, '-');

        // Parse architecture (required)
        const arch_str = iter.next() orelse return ParseError.InvalidTriplet;
        const arch = try Arch.parse(arch_str);

        // Parse vendor (required)
        const vendor_str = iter.next() orelse return ParseError.InvalidTriplet;
        const vendor = Vendor.parse(vendor_str);

        // Parse OS (required)
        const os_str = iter.next() orelse return ParseError.InvalidTriplet;
        const os = try Os.parse(os_str);

        // Parse ABI (optional)
        var abi: Abi = .none;
        if (iter.next()) |abi_str| {
            abi = Abi.parse(abi_str) catch .none;
        }

        return .{
            .arch = arch,
            .vendor = vendor,
            .os = os,
            .abi = abi,
        };
    }

    /// Creates a platform from individual components.
    pub fn init(arch: Arch, os: Os, abi: Abi) Self {
        const vendor: Vendor = if (os.isApple()) .apple else if (os == .windows) .pc else .unknown;
        return .{
            .arch = arch,
            .vendor = vendor,
            .os = os,
            .abi = abi,
        };
    }

    /// Returns the target triplet string.
    /// Caller owns the returned memory.
    pub fn triplet(self: Self, allocator: Allocator) Allocator.Error![]u8 {
        if (self.abi.toString()) |abi_str| {
            return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}", .{
                self.arch.toString(),
                self.vendor.toString(),
                self.os.toString(),
                abi_str,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
                self.arch.toString(),
                self.vendor.toString(),
                self.os.toString(),
            });
        }
    }

    /// Writes the triplet to a fixed buffer (no allocation).
    /// Returns the slice of the buffer that was written to.
    pub fn tripletBuf(self: Self, buf: []u8) []u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        writer.print("{s}-{s}-{s}", .{
            self.arch.toString(),
            self.vendor.toString(),
            self.os.toString(),
        }) catch return buf[0..0];

        if (self.abi.toString()) |abi_str| {
            writer.print("-{s}", .{abi_str}) catch {};
        }

        return fbs.getWritten();
    }

    /// Returns true if this platform matches the native platform.
    pub fn isNative(self: Self) bool {
        const native = detect();
        return self.arch == native.arch and self.os == native.os;
    }

    /// Returns true if this is a cross-compilation target.
    pub fn isCrossCompile(self: Self) bool {
        return !self.isNative();
    }
};

/// Common predefined platforms for convenience.
pub const PredefinedPlatforms = struct {
    pub const linux_x86_64_gnu = Platform{
        .arch = .x86_64,
        .vendor = .unknown,
        .os = .linux,
        .abi = .gnu,
    };

    pub const linux_x86_64_musl = Platform{
        .arch = .x86_64,
        .vendor = .unknown,
        .os = .linux,
        .abi = .musl,
    };

    pub const linux_aarch64_gnu = Platform{
        .arch = .aarch64,
        .vendor = .unknown,
        .os = .linux,
        .abi = .gnu,
    };

    pub const macos_x86_64 = Platform{
        .arch = .x86_64,
        .vendor = .apple,
        .os = .macos,
        .abi = .none,
    };

    pub const macos_aarch64 = Platform{
        .arch = .aarch64,
        .vendor = .apple,
        .os = .macos,
        .abi = .none,
    };

    pub const windows_x86_64_msvc = Platform{
        .arch = .x86_64,
        .vendor = .pc,
        .os = .windows,
        .abi = .msvc,
    };

    pub const windows_x86_64_gnu = Platform{
        .arch = .x86_64,
        .vendor = .pc,
        .os = .windows,
        .abi = .gnu,
    };

    pub const wasm32_wasi = Platform{
        .arch = .wasm32,
        .vendor = .unknown,
        .os = .wasi,
        .abi = .none,
    };

    pub const wasm32_freestanding = Platform{
        .arch = .wasm32,
        .vendor = .unknown,
        .os = .freestanding,
        .abi = .none,
    };
};

/// Errors that can occur when parsing platform specifications.
pub const ParseError = error{
    InvalidArch,
    InvalidOs,
    InvalidAbi,
    InvalidTriplet,
};

// ============================================================================
// Tests
// ============================================================================

test "Arch.parse" {
    try testing.expectEqual(Arch.x86_64, try Arch.parse("x86_64"));
    try testing.expectEqual(Arch.x86_64, try Arch.parse("amd64"));
    try testing.expectEqual(Arch.aarch64, try Arch.parse("aarch64"));
    try testing.expectEqual(Arch.aarch64, try Arch.parse("arm64"));
    try testing.expectEqual(Arch.x86, try Arch.parse("i686"));
    try testing.expectError(ParseError.InvalidArch, Arch.parse("invalid"));
}

test "Arch.pointerBits" {
    try testing.expectEqual(@as(u8, 32), Arch.x86.pointerBits());
    try testing.expectEqual(@as(u8, 64), Arch.x86_64.pointerBits());
    try testing.expectEqual(@as(u8, 64), Arch.aarch64.pointerBits());
    try testing.expectEqual(@as(u8, 32), Arch.wasm32.pointerBits());
}

test "Os.parse" {
    try testing.expectEqual(Os.linux, try Os.parse("linux"));
    try testing.expectEqual(Os.macos, try Os.parse("macos"));
    try testing.expectEqual(Os.macos, try Os.parse("darwin"));
    try testing.expectEqual(Os.windows, try Os.parse("windows"));
    try testing.expectEqual(Os.windows, try Os.parse("win32"));
    try testing.expectError(ParseError.InvalidOs, Os.parse("invalid"));
}

test "Os.isUnixLike" {
    try testing.expect(Os.linux.isUnixLike());
    try testing.expect(Os.macos.isUnixLike());
    try testing.expect(Os.freebsd.isUnixLike());
    try testing.expect(!Os.windows.isUnixLike());
    try testing.expect(!Os.freestanding.isUnixLike());
}

test "Os.extensions" {
    try testing.expectEqualStrings(".exe", Os.windows.exeExtension());
    try testing.expectEqualStrings("", Os.linux.exeExtension());
    try testing.expectEqualStrings(".dll", Os.windows.sharedLibExtension());
    try testing.expectEqualStrings(".so", Os.linux.sharedLibExtension());
    try testing.expectEqualStrings(".dylib", Os.macos.sharedLibExtension());
}

test "Platform.parse" {
    const linux = try Platform.parse("x86_64-unknown-linux-gnu");
    try testing.expectEqual(Arch.x86_64, linux.arch);
    try testing.expectEqual(Vendor.unknown, linux.vendor);
    try testing.expectEqual(Os.linux, linux.os);
    try testing.expectEqual(Abi.gnu, linux.abi);

    const macos = try Platform.parse("aarch64-apple-macos");
    try testing.expectEqual(Arch.aarch64, macos.arch);
    try testing.expectEqual(Vendor.apple, macos.vendor);
    try testing.expectEqual(Os.macos, macos.os);

    const windows = try Platform.parse("x86_64-pc-windows-msvc");
    try testing.expectEqual(Arch.x86_64, windows.arch);
    try testing.expectEqual(Vendor.pc, windows.vendor);
    try testing.expectEqual(Os.windows, windows.os);
    try testing.expectEqual(Abi.msvc, windows.abi);
}

test "Platform.triplet" {
    var buf: [64]u8 = undefined;

    const linux = PredefinedPlatforms.linux_x86_64_gnu;
    const linux_triplet = linux.tripletBuf(&buf);
    try testing.expectEqualStrings("x86_64-unknown-linux-gnu", linux_triplet);

    const macos = PredefinedPlatforms.macos_aarch64;
    const macos_triplet = macos.tripletBuf(&buf);
    try testing.expectEqualStrings("aarch64-apple-macos", macos_triplet);
}

test "Platform.detect" {
    const native = Platform.detect();
    try testing.expect(native.arch != .unknown);
    try testing.expect(native.os != .unknown);
    try testing.expect(native.isNative());
    try testing.expect(!native.isCrossCompile());
}

test "PredefinedPlatforms" {
    try testing.expectEqual(Arch.x86_64, PredefinedPlatforms.linux_x86_64_gnu.arch);
    try testing.expectEqual(Os.linux, PredefinedPlatforms.linux_x86_64_gnu.os);
    try testing.expectEqual(Abi.gnu, PredefinedPlatforms.linux_x86_64_gnu.abi);

    try testing.expectEqual(Arch.aarch64, PredefinedPlatforms.macos_aarch64.arch);
    try testing.expectEqual(Os.macos, PredefinedPlatforms.macos_aarch64.os);
    try testing.expectEqual(Vendor.apple, PredefinedPlatforms.macos_aarch64.vendor);
}
