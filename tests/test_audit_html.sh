#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/helpers.sh"
source "$PROJECT_DIR/audit_html.sh"

echo "=== audit_html.sh unit tests ==="

echo "--- Gate function ---"
tmp=$(mktemp); echo "ok" > "$tmp"
is_valid_html_page "200" "text/html; charset=utf-8" "$tmp"; assert_eq "200 + text/html" 0 $?
is_valid_html_page "403" "text/html" "$tmp"; assert_eq "403 status" 1 $?
is_valid_html_page "200" "application/json" "$tmp"; assert_eq "JSON content type" 1 $?
is_valid_html_page "200" "application/xhtml+xml" "$tmp"; assert_eq "XHTML content type" 0 $?
is_valid_html_page "200" "text/html" /dev/null 2>/dev/null; assert_eq "empty body" 1 $?
rm -f "$tmp"

echo "--- All-pass HTML ---"
outdir=$(mktemp -d); mkdir -p "$outdir"
run_html_audit "$SCRIPT_DIR/fixtures/html/valid_page.html" "$outdir" 2>/dev/null || true
assert_file_exists "audit_html.json created" "$outdir/audit_html.json"
assert_json_value "title_present" "$outdir/audit_html.json" ".title_present" "true"
assert_json_value "h1_count" "$outdir/audit_html.json" ".h1_count" "1"
assert_json_value "lang_present" "$outdir/audit_html.json" ".lang_present" "true"
assert_json_value "lang_value" "$outdir/audit_html.json" ".lang_value" "es"
assert_json_value "viewport_present" "$outdir/audit_html.json" ".viewport_present" "true"
assert_json_value "canonical_present" "$outdir/audit_html.json" ".canonical_present" "true"
assert_json_value "charset_present" "$outdir/audit_html.json" ".charset_present" "true"
assert_json_value "meta_robots_present" "$outdir/audit_html.json" ".meta_robots_present" "true"
assert_json_value "og_title_present" "$outdir/audit_html.json" ".og_title_present" "true"
assert_json_value "structured_data_present" "$outdir/audit_html.json" ".structured_data_present" "true"
assert_json_value "images_missing_alt_count" "$outdir/audit_html.json" ".images_missing_alt_count" "0"
rm -rf "$outdir"

echo "--- All-fail HTML ---"
outdir=$(mktemp -d); mkdir -p "$outdir"
run_html_audit "$SCRIPT_DIR/fixtures/html/no_title.html" "$outdir" 2>/dev/null || true
assert_json_value "h1_count" "$outdir/audit_html.json" ".h1_count" "1"
assert_json_value "meta_description false" "$outdir/audit_html.json" ".meta_description_present" "false"
rm -rf "$outdir"

echo "--- Multiple H1 ---"
outdir=$(mktemp -d); mkdir -p "$outdir"
run_html_audit "$SCRIPT_DIR/fixtures/html/multiple_h1.html" "$outdir" 2>/dev/null || true
assert_json_value "h1_count 2" "$outdir/audit_html.json" ".h1_count" "2"
rm -rf "$outdir"

echo "--- Missing alt ---"
outdir=$(mktemp -d); mkdir -p "$outdir"
run_html_audit "$SCRIPT_DIR/fixtures/html/missing_alt.html" "$outdir" 2>/dev/null || true
assert_json_value "images_missing_alt" "$outdir/audit_html.json" ".images_missing_alt_count" "2"
rm -rf "$outdir"

echo "--- Valid JSON ---"
outdir=$(mktemp -d); mkdir -p "$outdir"
run_html_audit "$SCRIPT_DIR/fixtures/html/valid_page.html" "$outdir" 2>/dev/null || true
jq empty "$outdir/audit_html.json" 2>/dev/null
assert_eq "valid JSON" 0 $?
rm -rf "$outdir"

echo "--- No-title safety ---"
outdir=$(mktemp -d); mkdir -p "$outdir"
run_html_audit "$SCRIPT_DIR/fixtures/html/no_title.html" "$outdir" 2>/dev/null || true
assert_file_exists "output exists (no crash)" "$outdir/audit_html.json"
rm -rf "$outdir"

finish_tests
