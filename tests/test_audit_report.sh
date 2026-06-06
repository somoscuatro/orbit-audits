#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/helpers.sh"
source "$PROJECT_DIR/audit_report.sh"

echo "=== audit_report.sh tests ==="

echo "--- _jq_safe ---"
t3_tmp1=$(mktemp); echo '{"a":1}' > "$t3_tmp1"
assert_eq "valid JSON" "1" "$(_jq_safe -r '.a' "$t3_tmp1")"

t3_tmp2=$(mktemp); echo 'not json' > "$t3_tmp2"
assert_eq "invalid JSON" "null" "$(_jq_safe -r '.a' "$t3_tmp2")"

assert_eq "missing file" "null" "$(_jq_safe -r '.a' /nonexistent)"

rm -f "$t3_tmp1" "$t3_tmp2"

echo "--- _html_extract_all ---"
extracted=$(_html_extract_all "$SCRIPT_DIR/fixtures/json/html_all_pass.json")
cols=$(echo "$extracted" | awk -F'\t' '{print NF}')
assert_eq "18 columns" "18" "$cols"

extracted=$(_html_extract_all "$SCRIPT_DIR/fixtures/json/html_all_fail.json")
cols=$(echo "$extracted" | awk -F'\t' '{print NF}')
assert_eq "18 columns (all-fail)" "18" "$cols"

echo "--- CSP detection ---"
assert_eq "CSP present+valid" "true" "$(_jq_safe -r 'if type == "array" then "true" else "false" end' "$SCRIPT_DIR/fixtures/json/csp_present_valid.json")"
assert_eq "CSP no-CSP object" "true" "$(_jq_safe -r 'if type == "object" and has("error") and (.error | startswith("No Content-Security-Policy")) then "true" else "false" end' "$SCRIPT_DIR/fixtures/json/csp_not_found.json")"
assert_eq "invalid severity count" "1" "$(_jq_safe -r '[.[]? | select(.severity >= 20)] | length' "$SCRIPT_DIR/fixtures/json/csp_present_invalid.json")"
assert_eq "valid severity count" "0" "$(_jq_safe -r '[.[]? | select(.severity >= 20)] | length' "$SCRIPT_DIR/fixtures/json/csp_present_valid.json")"

echo "--- run_report integration ---"

tmpdir=$(mktemp -d)
cp "$SCRIPT_DIR/fixtures/json/psi_general.json" "$tmpdir/audit_general_mobile.json"
cp "$SCRIPT_DIR/fixtures/json/psi_general.json" "$tmpdir/audit_general_desktop.json"
cp "$SCRIPT_DIR/fixtures/json/pa11y_output.json" "$tmpdir/audit_accessibility.json"
cp "$SCRIPT_DIR/fixtures/json/sec_headers_mixed.json" "$tmpdir/audit_security_headers.json"
cp "$SCRIPT_DIR/fixtures/json/csp_present_valid.json" "$tmpdir/audit_csp.json"
cp "$SCRIPT_DIR/fixtures/json/html_all_pass.json" "$tmpdir/audit_html.json"

run_report "$tmpdir" "https://test.example.com" "focused" "json" 2>/dev/null || true
assert_file_exists "summary.json created" "$tmpdir/summary.json"
assert_json_value "mobile perf" "$tmpdir/summary.json" ".scores.mobile.performance" "43"
assert_json_value "desktop perf" "$tmpdir/summary.json" ".scores.desktop.performance" "43"
assert_json_value "security pass" "$tmpdir/summary.json" ".security_headers.pass" "4"
assert_json_value "csp present" "$tmpdir/summary.json" ".csp.present" "true"
assert_json_value "csp valid" "$tmpdir/summary.json" ".csp.valid" "true"
assert_json_value "html title" "$tmpdir/summary.json" ".html.title_present" "true"

# only security files present
tmpdir2=$(mktemp -d)
cp "$SCRIPT_DIR/fixtures/json/sec_headers_pass.json" "$tmpdir2/audit_security_headers.json"
cp "$SCRIPT_DIR/fixtures/json/csp_present_invalid.json" "$tmpdir2/audit_csp.json"
run_report "$tmpdir2" "https://sec-only.example.com" "focused" "json" 2>/dev/null || true
assert_json_value "scores null" "$tmpdir2/summary.json" ".scores" "null"
assert_json_value "security populated" "$tmpdir2/summary.json" ".security_headers.pass" "6"
assert_json_value "csp invalid" "$tmpdir2/summary.json" ".csp.valid" "false"

# report.md focused mode
tmpdir3=$(mktemp -d)
cp "$SCRIPT_DIR/fixtures/json/psi_general.json" "$tmpdir3/audit_general_mobile.json"
cp "$SCRIPT_DIR/fixtures/json/pa11y_output.json" "$tmpdir3/audit_accessibility.json"
cp "$SCRIPT_DIR/fixtures/json/sec_headers_mixed.json" "$tmpdir3/audit_security_headers.json"
cp "$SCRIPT_DIR/fixtures/json/csp_present_invalid.json" "$tmpdir3/audit_csp.json"
cp "$SCRIPT_DIR/fixtures/json/html_all_fail.json" "$tmpdir3/audit_html.json"
run_report "$tmpdir3" "https://focused.example.com" "focused" "markdown" 2>/dev/null || true
assert_file_exists "report.md created" "$tmpdir3/report.md"
md_content=$(cat "$tmpdir3/report.md")
assert_contains "has performance section" "## Performance" "$md_content"
assert_contains "has accessibility section" "## Accessibility" "$md_content"
assert_contains "has SEO section" "## SEO & Structure" "$md_content"
assert_contains "has security section" "## Security" "$md_content"
assert_contains "mentions missing title" "Missing \`<title>\` tag" "$md_content"
assert_not_contains "no Pa11y warnings in focused" "Pa11y warnings:" "$md_content"

# report.md complete mode
run_report "$tmpdir3" "https://complete.example.com" "complete" "markdown" 2>/dev/null || true
md_comp=$(cat "$tmpdir3/report.md")
assert_contains "Pa11y warnings in complete" "Pa11y warnings:" "$md_comp"

# Uses $md_content from the focused-mode run above — the complete-mode run on
# the next line overwrites report.md, so the focused output was captured earlier.
assert_contains "CSP first violation" "First violation:" "$md_content"

rm -rf "$tmpdir" "$tmpdir2" "$tmpdir3"

finish_tests
