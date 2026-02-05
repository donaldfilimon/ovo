//! ZON (Zig Object Notation) processing for build.zon files.
//!
//! This module provides parsing, validation, generation, and merging of build.zon
//! configuration files used by the ovo package manager.
//!
//! ## Features
//! - Parse build.zon files using Zig's std.zon parser
//! - Validate schemas with detailed error messages
//! - Generate build.zon files from Project model
//! - Merge workspace + member configurations
//! - Apply profile overrides
//!
//! ## Example
//! ```zig
//! const zon = @import("zon");
//!
//! // Parse a build.zon file
//! var project = try zon.parser.parseFile(allocator, "build.zon");
//! defer project.deinit(allocator);
//!
//! // Validate the project
//! var ctx = zon.schema.ValidationContext.init(allocator);
//! defer ctx.deinit();
//! try zon.schema.validateProject(&project, &ctx);
//!
//! // Apply a build profile
//! try zon.merge.applyProfile(allocator, &project, "release");
//!
//! // Generate a new build.zon
//! const output = try zon.writer.writeProject(allocator, &project, .{});
//! defer allocator.free(output);
//! ```

pub const parser = @import("parser.zig");
pub const schema = @import("schema.zig");
pub const writer = @import("writer.zig");
pub const merge = @import("merge.zig");

// Re-export commonly used types from parser
pub const ParseError = parser.ParseError;
pub const ParserContext = parser.ParserContext;
pub const parseFile = parser.parseFile;
pub const parseSource = parser.parseSource;
pub const parseSourceWithContext = parser.parseSourceWithContext;

// Re-export commonly used types from schema
pub const ValidationError = schema.ValidationError;
pub const ValidationContext = schema.ValidationContext;
pub const validateProject = schema.validateProject;

// Re-export all schema types
pub const Project = schema.Project;
pub const Target = schema.Target;
pub const TargetType = schema.TargetType;
pub const Dependency = schema.Dependency;
pub const DependencySource = schema.DependencySource;
pub const Version = schema.Version;
pub const Defaults = schema.Defaults;
pub const SourceSpec = schema.SourceSpec;
pub const IncludeSpec = schema.IncludeSpec;
pub const DefineSpec = schema.DefineSpec;
pub const FlagSpec = schema.FlagSpec;
pub const PlatformFilter = schema.PlatformFilter;
pub const TestSpec = schema.TestSpec;
pub const BenchmarkSpec = schema.BenchmarkSpec;
pub const ExampleSpec = schema.ExampleSpec;
pub const ScriptSpec = schema.ScriptSpec;
pub const HookType = schema.HookType;
pub const Profile = schema.Profile;
pub const CrossTarget = schema.CrossTarget;
pub const Feature = schema.Feature;
pub const ModuleSettings = schema.ModuleSettings;
pub const CppStandard = schema.CppStandard;
pub const CStandard = schema.CStandard;
pub const Compiler = schema.Compiler;
pub const Optimization = schema.Optimization;
pub const OsTag = schema.OsTag;
pub const CpuArch = schema.CpuArch;
pub const isValidGlobPattern = schema.isValidGlobPattern;

// Re-export writer types and functions
pub const WriterOptions = writer.WriterOptions;
pub const ZonWriter = writer.ZonWriter;
pub const writeProject = writer.writeProject;
pub const writeProjectToFile = writer.writeProjectToFile;
pub const createMinimalTemplate = writer.createMinimalTemplate;
pub const createLibraryTemplate = writer.createLibraryTemplate;

// Re-export merge types and functions
pub const MergeStrategy = merge.MergeStrategy;
pub const MergeOptions = merge.MergeOptions;
pub const mergeProjects = merge.mergeProjects;
pub const applyProfile = merge.applyProfile;
pub const applyDefaults = merge.applyDefaults;
pub const resolveFeatures = merge.resolveFeatures;
pub const applyCrossTarget = merge.applyCrossTarget;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
