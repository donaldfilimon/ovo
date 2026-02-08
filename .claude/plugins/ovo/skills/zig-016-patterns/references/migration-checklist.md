# Zig 0.16 Migration Checklist

File-by-file status for migrating deprecated API calls.

## std.fs.cwd() Migration Status

### translate/ (~30 calls)
- [ ] `src/translate/cmake.zig`
- [ ] `src/translate/meson.zig`
- [ ] `src/translate/ninja.zig`
- [ ] `src/translate/xcode.zig`
- [ ] `src/translate/msbuild.zig`
- [ ] `src/translate/importers/*.zig`
- [ ] `src/translate/exporters/*.zig`

### compiler/ (~18 calls)
- [ ] `src/compiler/zig_cc.zig`
- [ ] `src/compiler/clang.zig`
- [ ] `src/compiler/gcc.zig`
- [ ] `src/compiler/msvc.zig`
- [ ] `src/compiler/emscripten.zig`
- [ ] `src/compiler/modules.zig`
- [ ] `src/compiler/interface.zig`

### util/ (~6 calls)
- [ ] `src/util/fs.zig`
- [ ] `src/util/process.zig`
- [ ] `src/util/glob.zig`

### package/ (~6 calls)
- [ ] `src/package/fetcher.zig`
- [ ] `src/package/resolver.zig`
- [ ] `src/package/sources/*.zig`

### cli/ (DONE)
- [x] All CLI files use DirHandle — no std.fs.cwd() calls

## std.posix.getenv() Migration Status

### compiler/ (7 calls)
- [ ] `src/compiler/zig_cc.zig` — PATH, CC lookups
- [ ] `src/compiler/clang.zig` — CLANG_PATH
- [ ] `src/compiler/gcc.zig` — GCC_PATH
- [ ] `src/compiler/interface.zig` — compiler selection

### package/ (6 calls)
- [ ] `src/package/fetcher.zig` — HTTP_PROXY, cache dirs
- [ ] `src/package/resolver.zig` — OVO_REGISTRY
- [ ] `src/package/sources/*.zig` — auth tokens

### util/ (4 calls)
- [ ] `src/util/process.zig` — PATH, SHELL
- [ ] `src/util/http.zig` — proxy settings

### cli/ (DONE)
- [x] Uses `std.c.getenv()` via DirHandle pattern

## Migration Procedure Per File

1. Add import: `const compat = @import("compat");`
2. Find: `std.fs.cwd()` → Replace: `compat.cwd()`
3. Find: `std.posix.getenv("KEY")` → Replace: `compat.getenv("KEY")`
4. Verify: `~/.zvm/bin/zig build check`
5. Test: `~/.zvm/bin/zig build test`

## Notes

- These calls are latent — Zig's lazy evaluation means they compile but fail at runtime
- Migration order: util/ first (least dependencies), then compiler/, package/, translate/
- CLI layer is already done — only non-CLI modules remain
