//! OVO - ZON-Based Package Manager and Build System for C/C++
//!
//! A modern replacement for CMake that uses Zig's ZON format for configuration
//! and Zig's compiler infrastructure for C/C++ compilation.
//!
//! ## Features
//! - Unified package management and build system (like Cargo for Rust)
//! - Support for C99-C23 and C++11-C++26
//! - Seamless C++20/23/26 modules support
//! - Multiple compiler backends (Zig's Clang, system Clang, GCC, MSVC)
//! - vcpkg and Conan integration
//! - Project translation (import/export CMake, Xcode, Visual Studio, Meson)
//!
//! ## Quick Start
//! ```bash
//! ovo new myproject     # create new project
//! ovo build             # compile
//! ovo run               # build and execute
//! ovo test              # run tests
//! ovo add fmt --git=https://github.com/fmtlib/fmt  # add dependency
//! ```
//!
//! ## build.zon Example
//! ```zon
//! .{
//!     .name = "myproject",
//!     .version = "1.0.0",
//!     .defaults = .{
//!         .cpp_standard = .cpp23,
//!     },
//!     .targets = .{
//!         .myapp = .{
//!             .type = .executable,
//!             .sources = .{ "src/main.cpp" },
//!         },
//!     },
//! }
//! ```

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Package Manager Modules
// ═══════════════════════════════════════════════════════════════════════════

/// Core data structures (Project, Target, Dependency, Profile, Platform).
pub const core = @import("core");

/// ZON parsing, validation, and generation for build.zon files.
pub const zon = @import("zon");

/// Build orchestration engine (compilation, caching, parallelization).
pub const build = @import("build");

/// Compiler abstraction layer (Zig CC, Clang, GCC, MSVC, Emscripten).
pub const compiler = @import("compiler");

/// Package management (fetching, resolution, lockfiles, sources).
pub const package = @import("package");

/// Build system translation (import/export CMake, Xcode, MSBuild, Meson).
pub const translate = @import("translate");

/// Command-line interface and command handlers.
pub const cli = @import("cli");

/// Utility functions (fs, process, hash, glob, semver, terminal, http).
pub const util = @import("util");

// ═══════════════════════════════════════════════════════════════════════════
// Version Information
// ═══════════════════════════════════════════════════════════════════════════

pub const version = "0.2.0";
pub const version_major = 0;
pub const version_minor = 2;
pub const version_patch = 0;

/// Semantic version as a struct for programmatic access.
pub const semantic_version = std.SemanticVersion{
    .major = version_major,
    .minor = version_minor,
    .patch = version_patch,
};

// ═══════════════════════════════════════════════════════════════════════════
// Legacy Neural Network Module (Preserved for Compatibility)
// ═══════════════════════════════════════════════════════════════════════════
//
// The original OVO project included a neural network implementation.
// These exports are preserved for backwards compatibility but are
// considered deprecated for new code.

/// Neural network implementation (deprecated - use dedicated ML libraries).
/// Access via `ovo.neural.Network`, `ovo.neural.activation`, etc.
pub const neural = @import("neural/root.zig");

// Legacy top-level exports (deprecated - use neural.* instead)
pub const network = neural.network;
pub const layer = neural.layer;
pub const activation = neural.activation;
pub const loss = neural.loss;
pub const csv = neural.csv;
pub const legacy_cli = neural.cli;

pub const Network = neural.Network;
pub const Gradients = neural.Gradients;
pub const trainStepMse = neural.trainStepMse;
pub const trainStepMseBatch = neural.trainStepMseBatch;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test {
    std.testing.refAllDecls(@This());
}

test "version information" {
    try std.testing.expectEqualStrings("0.2.0", version);
    try std.testing.expectEqual(@as(u32, 0), version_major);
    try std.testing.expectEqual(@as(u32, 2), version_minor);
    try std.testing.expectEqual(@as(u32, 0), version_patch);
}
