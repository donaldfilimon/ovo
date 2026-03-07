#!/usr/bin/env bash
set -euo pipefail

required_tools=(
  zig
  clang-format
  clang-tidy
  clang++
  g++
  cmake
  ninja
  doxygen
  clang-doc
)

missing_tools=()
for tool in "${required_tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'check-cli-test-env: found %s\n' "$tool"
  else
    printf 'check-cli-test-env: missing %s\n' "$tool" >&2
    missing_tools+=("$tool")
  fi
done

if (( ${#missing_tools[@]} > 0 )); then
  printf 'check-cli-test-env: missing required tools (%d): %s\n' \
    "${#missing_tools[@]}" "${missing_tools[*]}" >&2
  exit 1
fi
