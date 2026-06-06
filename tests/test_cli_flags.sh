#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== CLI flag tests ==="

BULK="$SCRIPT_DIR/../bulk_audits.sh"

# invalid --report value
tmp_urls=$(mktemp)
echo "test" > "$tmp_urls"
out=$(bash "$BULK" --report invalid "$tmp_urls" 2>&1); rc=$?
assert_eq "invalid --report → exit 1" "1" "$rc"
assert_contains "error message" "Invalid report mode" "$out"
rm -f "$tmp_urls"

# invalid AUDIT_TYPE
out=$(bash "$BULK" /dev/null invalidtype 2>&1); rc=$?
assert_eq "invalid type → exit 1" "1" "$rc"

# missing URLs file
out=$(bash "$BULK" 2>&1); rc=$?
assert_eq "missing file → exit 1" "1" "$rc"

# html type is accepted (not rejected as invalid)
tmp_urls2=$(mktemp)
echo "http://127.0.0.1:1" > "$tmp_urls2"
out=$(bash "$BULK" "$tmp_urls2" html 2>&1) || true
assert_not_contains "html type accepted" "Invalid audit type" "$out"
rm -f "$tmp_urls2"

# --help
out=$(bash "$BULK" --help 2>&1); rc=$?
assert_eq "--help exit 0" "0" "$rc"
assert_contains "mentions html type" "html" "$out"
assert_contains "mentions --report" "--report" "$out"
assert_not_contains "no --format in help" "--format" "$out"

# unknown option
out=$(bash "$BULK" --unknown /dev/null 2>&1); rc=$?
assert_eq "unknown option → exit 1" "1" "$rc"

finish_tests
