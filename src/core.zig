//! Core data structures for the ovo package manager.
//!
//! This module provides the foundational types for representing C/C++ projects,
//! build targets, dependencies, and build configurations. These types are used
//! throughout the ovo build system for configuration, dependency resolution,
//! and build orchestration.
//!
//! ## Modules
//! - `project`: Complete project configuration with ZON support
//! - `target`: Build targets (executables, libraries)
//! - `dependency`: External dependency specifications
//! - `profile`: Build profiles (debug, release, custom)
//! - `workspace`: Monorepo/workspace support
//! - `platform`: Platform detection and cross-compilation
//! - `standard`: C/C++ language standard definitions
//!
//! ## Example
//! ```zig
//! const core = @import("core.zig");
//!
//! const project = core.Project{
//!     .name = "myapp",
//!     .version = core.Version.init(1, 0, 0),
//!     .cpp_standard = .cpp20,
//!     .targets = &.{
//!         .{
//!             .name = "myapp",
//!             .kind = .executable,
//!             .sources = &.{"src/main.cpp"},
//!         },
//!     },
//! };
//! ```

const std = @import("std");

// Core modules
pub const project = @import("core/project.zig");
pub const target = @import("core/target.zig");
pub const dependency = @import("core/dependency.zig");
pub const profile = @import("core/profile.zig");
pub const workspace = @import("core/workspace.zig");
pub const platform = @import("core/platform.zig");
pub const standard = @import("core/standard.zig");

// Re-export primary types for convenience
pub const Project = project.Project;
pub const Version = project.Version;
pub const Feature = project.Feature;
pub const Metadata = project.Metadata;
pub const Hooks = project.Hooks;
pub const Script = project.Script;

pub const Target = target.Target;
pub const TargetKind = target.TargetKind;
pub const SourceFile = target.SourceFile;
pub const Define = target.Define;
pub const IncludeDir = target.IncludeDir;
pub const LinkLibrary = target.LinkLibrary;
pub const PlatformConfig = target.PlatformConfig;
pub const PlatformMatcher = target.PlatformMatcher;

pub const Dependency = dependency.Dependency;
pub const DependencyBuilder = dependency.DependencyBuilder;
pub const Source = dependency.Source;
pub const GitSource = dependency.GitSource;
pub const UrlSource = dependency.UrlSource;
pub const PathSource = dependency.PathSource;
pub const VcpkgSource = dependency.VcpkgSource;
pub const ConanSource = dependency.ConanSource;
pub const SystemSource = dependency.SystemSource;
pub const LinkType = dependency.LinkType;
pub const VersionConstraint = dependency.VersionConstraint;

pub const Profile = profile.Profile;
pub const OptimizationLevel = profile.OptimizationLevel;
pub const DebugInfo = profile.DebugInfo;
pub const Sanitizers = profile.Sanitizers;
pub const Lto = profile.Lto;

pub const Workspace = workspace.Workspace;
pub const Member = workspace.Member;
pub const SharedSettings = workspace.SharedSettings;
pub const DependencyGraph = workspace.DependencyGraph;

pub const Platform = platform.Platform;
pub const Arch = platform.Arch;
pub const Os = platform.Os;
pub const Abi = platform.Abi;
pub const Vendor = platform.Vendor;
pub const PredefinedPlatforms = platform.PredefinedPlatforms;

pub const CStandard = standard.CStandard;
pub const CppStandard = standard.CppStandard;
pub const Compiler = standard.Compiler;
pub const LanguageStandard = standard.LanguageStandard;

// ============================================================================
// Tests - run all submodule tests
// ============================================================================

test {
    // Import all test blocks from submodules
    _ = @import("core/project.zig");
    _ = @import("core/target.zig");
    _ = @import("core/dependency.zig");
    _ = @import("core/profile.zig");
    _ = @import("core/workspace.zig");
    _ = @import("core/platform.zig");
    _ = @import("core/standard.zig");
}

test "core module exports" {
    // Verify that all expected types are accessible
    const _project = Project{
        .name = "test",
    };
    _ = _project;

    const _version = Version.init(1, 0, 0);
    _ = _version;

    const _platform = Platform.detect();
    _ = _platform;

    const _profile = Profile.debug;
    _ = _profile;
}
