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

echo "--- ovo info ---"
"$OVO" info 2>/dev/null

echo "--- ovo deps ---"
"$OVO" deps 2>/dev/null

echo "--- ovo add (git dep) ---"
"$OVO" add mylib --git https://github.com/example/mylib.git 2>/dev/null

echo "--- ovo deps (after add) ---"
OUTPUT=$("$OVO" deps 2>&1)
echo "$OUTPUT" | grep -q "mylib" || { echo "FAIL: mylib not in deps"; exit 1; }

echo "--- ovo lock (with dep) ---"
"$OVO" lock 2>/dev/null
[ -f ovo.lock ] || { echo "FAIL: ovo.lock not created"; exit 1; }

echo "--- ovo remove mylib ---"
"$OVO" remove mylib 2>/dev/null

echo "--- ovo deps (after remove) ---"
OUTPUT=$("$OVO" deps 2>&1)
if echo "$OUTPUT" | grep -q "mylib"; then
  echo "FAIL: mylib still in deps after remove"
  exit 1
fi

echo "--- ovo fetch ---"
"$OVO" fetch 2>/dev/null

echo "--- ovo update ---"
"$OVO" update 2>/dev/null

echo "--- ovo doc ---"
"$OVO" doc 2>/dev/null || true

echo "--- ovo clean ---"
"$OVO" clean 2>/dev/null

echo "=== Integration test passed ==="
