#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL=0; FAIL=0

echo "=========================================="
echo " Orbit Audits — Test Suite"
echo "=========================================="
echo ""

for test_script in "$SCRIPT_DIR"/test_*.sh; do
  echo "Running $(basename "$test_script")..."
  if bash "$test_script"; then
    echo "  PASS"
  else
    echo "  FAIL"
    FAIL=$((FAIL + 1))
  fi
  TOTAL=$((TOTAL + 1))
  echo ""
done

echo "=========================================="
echo " FILES: $TOTAL total, $FAIL failed"
echo "=========================================="

[[ $FAIL -gt 0 ]] && exit 1 || exit 0
