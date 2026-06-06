#!/usr/bin/env bash

# Global counters — safe for isolated runs because each test script is executed
# in its own subshell (bash "$test_script"). If tests are ever sourced directly
# by run_all.sh instead, counters will bleed between suites.

PASSED=0
FAILED=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ((PASSED++)); echo "  PASS: $label"
  else
    ((FAILED++)); echo "  FAIL: $label — expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ((PASSED++)); echo "  PASS: $label"
  else
    ((FAILED++)); echo "  FAIL: $label — '$needle' not found"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ((PASSED++)); echo "  PASS: $label"
  else
    ((FAILED++)); echo "  FAIL: $label — '$needle' found but should not be present"
  fi
}

assert_file_exists() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then
    ((PASSED++)); echo "  PASS: $label"
  else
    ((FAILED++)); echo "  FAIL: $label — file '$file' does not exist"
  fi
}

assert_json_value() {
  local label="$1" file="$2" filter="$3" expected="$4"
  if [[ ! -f "$file" ]]; then
    ((FAILED++)); echo "  FAIL: $label — file '$file' not found"
    return
  fi
  local actual
  actual=$(jq -r "$filter" "$file" 2>/dev/null) || true
  if [[ "$actual" == "$expected" ]]; then
    ((PASSED++)); echo "  PASS: $label"
  else
    ((FAILED++)); echo "  FAIL: $label — expected '$expected', got '$actual'"
  fi
}

finish_tests() {
  local total=$((PASSED + FAILED))
  echo ""
  echo "Results: $PASSED/$total passed, $FAILED failed"
  [[ $FAILED -gt 0 ]] && return 1 || return 0
}
