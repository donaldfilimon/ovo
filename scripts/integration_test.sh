#!/usr/bin/env sh
# Integration test: ovo new && ovo build && ovo run
# Run from repo root: zig build && ./scripts/integration_test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVO="${OVO:-$REPO_ROOT/zig-out/bin/ovo}"
TEMPLATES="${OVO_TEMPLATES:-$REPO_ROOT/templates}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export OVO_TEMPLATES="$TEMPLATES"
cd "$TEST_DIR"

echo "=== Integration test in $TEST_DIR ==="

echo "--- ovo new demo ---"
"$OVO" new demo 2>/dev/null
cd demo

echo "--- ovo build ---"
"$OVO" build 2>/dev/null

echo "--- ovo run ---"
"$OVO" run 2>/dev/null

echo "=== Integration test passed ==="
