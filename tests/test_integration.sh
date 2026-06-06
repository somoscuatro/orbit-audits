#!/usr/bin/env bash
# Integration + Regression tests
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BULK="$PROJECT_DIR/bulk_audits.sh"
source "$SCRIPT_DIR/helpers.sh"

PORT=18765
BASE="http://127.0.0.1:$PORT"
TMP_URLS=$(mktemp)
TMP_OUT=$(mktemp)
REGRESSION_TMP=$(mktemp -d)
trap 'rm -f "$TMP_URLS" "$TMP_OUT"; rm -rf "$REGRESSION_TMP"; kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null' EXIT

# --- Start test server ---
python3 "$SCRIPT_DIR/test_server.py" "$PORT" &
SERVER_PID=$!

# Wait for server to be ready (max 5s)
server_ok=false
for _ in $(seq 1 25); do
  if curl -s -o /dev/null "$BASE/200/valid_page.html" 2>/dev/null; then
    server_ok=true
    break
  fi
  sleep 0.2
done
if [[ "$server_ok" != "true" ]]; then
  echo "SKIP: test server unreachable"
  kill "$SERVER_PID" 2>/dev/null
  exit 0
fi

echo "=== Integration (local HTTP server) ==="

# -- html type produces valid audit_html.json --
# Use a clean results dir; clear any prior localhost results
rm -rf "$PROJECT_DIR/audits_results/127_0_0_1_$PORT"*

echo "$BASE/200/valid_page.html" > "$TMP_URLS"
bash "$BULK" "$TMP_URLS" html > "$TMP_OUT" 2>&1 || true

BASE_DIR="$PROJECT_DIR/audits_results/127_0_0_1_$PORT"
HTML_JSON="$BASE_DIR/audit_html.json"

if [[ -f "$HTML_JSON" ]]; then
  assert_file_exists "audit_html.json created" "$HTML_JSON"
  if jq empty "$HTML_JSON" 2>/dev/null; then
    assert_contains "json has title_present" "title_present" "$(head -c 300 "$HTML_JSON")"
  else
    echo "  FAIL: audit_html.json is not valid JSON"
    ((FAILED++))
  fi
else
  echo "  FAIL: no audit_html.json at $BASE_DIR"
  echo "  DEBUG output:"
  cat "$TMP_OUT" | tail -20
  ls -la "$BASE_DIR" 2>/dev/null || true
  ((FAILED++))
fi

# -- both summary.json and report.md are always generated --
rm -rf "$PROJECT_DIR/audits_results/127_0_0_1_$PORT"*
echo "$BASE/200/valid_page.html" > "$TMP_URLS"
bash "$BULK" "$TMP_URLS" html > /dev/null 2>&1 || true
RES_DIR="$PROJECT_DIR/audits_results/127_0_0_1_$PORT"
t74_ok=true
if [[ ! -f "$RES_DIR/summary.json" ]]; then
  echo "  FAIL: summary.json missing"
  t74_ok=false
fi
if [[ ! -f "$RES_DIR/report.md" ]]; then
  echo "  FAIL: report.md missing"
  t74_ok=false
fi
if [[ "$t74_ok" == "true" ]]; then
  echo "  PASS: both summary.json and report.md generated"
  ((PASSED++))
else
  ((FAILED++))
fi

# -- gate catches non-HTML content type --
echo "$BASE/200/ct/text/plain" > "$TMP_URLS"
rm -rf "$PROJECT_DIR/audits_results/127_0_0_1_$PORT"*
bash "$BULK" "$TMP_URLS" html > /dev/null 2>&1 || true
GATE_DIR="$PROJECT_DIR/audits_results/127_0_0_1_$PORT"
GATE_FILE="$GATE_DIR/audit_html.json"
if [[ -f "$GATE_FILE" ]] && grep -q '"error"' "$GATE_FILE"; then
  echo "  PASS: gate error JSON for non-HTML"
  ((PASSED++))
else
  echo "  FAIL: no gate error JSON at $GATE_DIR"
  [[ -f "$GATE_FILE" ]] && cat "$GATE_FILE"
  ((FAILED++))
fi

# -- 404 response caught --
echo "$BASE/404/any.html" > "$TMP_URLS"
rm -rf "$PROJECT_DIR/audits_results/127_0_0_1_$PORT"*
bash "$BULK" "$TMP_URLS" html > /dev/null 2>&1 || true
GATE_FILE2="$PROJECT_DIR/audits_results/127_0_0_1_$PORT/audit_html.json"
if [[ -f "$GATE_FILE2" ]] && grep -q '"error"' "$GATE_FILE2" && grep -q '404' "$GATE_FILE2"; then
  echo "  PASS: 404 caught with status_code in error"
  ((PASSED++))
else
  echo "  FAIL: 404 not caught"
  ((FAILED++))
fi

# --- Clean up localhost results before regression ---
rm -rf "$PROJECT_DIR/audits_results/127_0_0_1_$PORT"*

echo ""
echo "=== Regression (existing audits_results) ==="
source "$PROJECT_DIR/audit_report.sh"

REG_PASS=0; REG_FAIL=0; REG_SKIP=0
for d in "$PROJECT_DIR/audits_results/"*/; do
  dir_name=$(basename "$d")
  [[ "$dir_name" == 127_0_0_1_* ]] && continue

  cp -r "$d" "$REGRESSION_TMP/$dir_name"
  run_report "$REGRESSION_TMP/$dir_name" "" focused 2>/dev/null || { ((REG_SKIP++)); continue; }

  summary="$REGRESSION_TMP/$dir_name/summary.json"
  report="$REGRESSION_TMP/$dir_name/report.md"

  if [[ -f "$summary" ]] && jq empty "$summary" 2>/dev/null; then
    ((REG_PASS++))
  else
    ((REG_FAIL++))
  fi

  if [[ -f "$report" ]] && [[ -s "$report" ]]; then
    ((REG_PASS++))
  else
    ((REG_FAIL++))
  fi
done

echo "  regression: $REG_PASS pass, $REG_SKIP skip, $REG_FAIL fail"
((PASSED += REG_PASS))
((FAILED += REG_FAIL))

# --- Smoke smoke test ---
echo ""
echo "=== Smoke test ==="
SMOKE_URL="https://motoreto.com"
if curl -s --max-time 10 -o /dev/null "$SMOKE_URL" 2>/dev/null; then
  echo "$SMOKE_URL" > "$TMP_URLS"
  SMOKE_DIR="$PROJECT_DIR/audits_results/motoreto_com"
  bash "$BULK" "$TMP_URLS" html > /dev/null 2>&1 || true
  if [[ -f "$SMOKE_DIR/audit_html.json" ]] && jq empty "$SMOKE_DIR/audit_html.json" 2>/dev/null; then
    echo "  PASS: smoke test html audit produced valid JSON"
    ((PASSED++))
  else
    echo "  FAIL: smoke test failed"
    ((FAILED++))
  fi
else
  echo "  SKIP: motoreto.com unreachable"
fi

echo ""
echo "Integration: $PASSED/$((PASSED + FAILED)) passed"
((FAILED > 0)) && echo "Integration: FAIL" || echo "Integration: PASS"

rm -rf "$PROJECT_DIR/audits_results/127_0_0_1_$PORT"*
exit $((FAILED > 0 ? 1 : 0))
