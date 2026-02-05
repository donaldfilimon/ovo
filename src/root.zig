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

// Core modules
pub const core = @import("core");
pub const zon = @import("zon");
pub const build = @import("build");
pub const compiler = @import("compiler");
pub const package = @import("package");
pub const translate = @import("translate");
pub const cli = @import("cli");
pub const util = @import("util");

// Version information
pub const version = "0.2.0";
pub const version_major = 0;
pub const version_minor = 2;
pub const version_patch = 0;

// Legacy neural network exports (preserved for compatibility)
pub const network = @import("network.zig");
pub const layer = @import("layer.zig");
pub const activation = @import("activation.zig");
pub const loss = @import("loss.zig");
pub const csv = @import("csv.zig");
pub const legacy_cli = @import("cli.zig");

pub const Network = network.Network;
pub const Gradients = network.Gradients;
pub const trainStepMse = network.trainStepMse;
pub const trainStepMseBatch = network.trainStepMseBatch;

test {
    std.testing.refAllDecls(@This());
}
