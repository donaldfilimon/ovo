#!/bin/bash
# OVO Full Verification Script
# Runs build, unit tests, and integration tests in sequence.
# Usage: bash .claude/plugins/ovo/skills/ovo-testing/scripts/run-full-verification.sh

set -euo pipefail

ZIG="${ZIG:-$HOME/.zvm/bin/zig}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

echo "=== OVO Full Verification ==="
echo "Zig: $ZIG"
echo "Root: $PROJECT_ROOT"
echo ""

# Step 1: Build
echo "--- Step 1: Build ---"
cd "$PROJECT_ROOT"
$ZIG build
echo "BUILD: PASS"
echo ""

# Step 2: Unit Tests
echo "--- Step 2: Unit Tests ---"
$ZIG build test
echo "UNIT TESTS: PASS"
echo ""

# Step 3: Integration Tests
echo "--- Step 3: Integration Tests ---"
export OVO_TEMPLATES="$PROJECT_ROOT/templates"
bash "$PROJECT_ROOT/scripts/integration_test.sh"
echo "INTEGRATION TESTS: PASS"
echo ""

echo "=== All Verification Steps Passed ==="
