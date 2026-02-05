//! Core data structures for the ovo package manager and build system.
//!
//! This module provides the fundamental types for representing projects,
//! targets, dependencies, profiles, platforms, and language standards.

pub const platform = @import("platform.zig");
pub const standard = @import("standard.zig");
pub const profile = @import("profile.zig");
pub const dependency = @import("dependency.zig");
pub const target = @import("target.zig");

// Re-export commonly used types
pub const Platform = platform.Platform;
pub const Arch = platform.Arch;
pub const Os = platform.Os;
pub const Vendor = platform.Vendor;
pub const Abi = platform.Abi;
pub const PredefinedPlatforms = platform.PredefinedPlatforms;

pub const CStandard = standard.CStandard;
pub const CppStandard = standard.CppStandard;
pub const Compiler = standard.Compiler;
pub const LanguageStandard = standard.LanguageStandard;

pub const Profile = profile.Profile;
pub const OptimizationLevel = profile.OptimizationLevel;
pub const DebugInfo = profile.DebugInfo;
pub const Sanitizers = profile.Sanitizers;
pub const Lto = profile.Lto;

pub const Dependency = dependency.Dependency;
pub const DependencySource = dependency.DependencySource;
pub const GitSource = dependency.GitSource;
pub const ArchiveSource = dependency.ArchiveSource;
pub const VcpkgSource = dependency.VcpkgSource;
pub const ConanSource = dependency.ConanSource;
pub const SystemSource = dependency.SystemSource;

pub const Target = target.Target;
pub const TargetKind = target.TargetKind;

test {
    @import("std").testing.refAllDecls(@This());
}
