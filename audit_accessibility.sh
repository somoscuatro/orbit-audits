#!/usr/bin/env bash

run_accessibility_audit() {
  local url="$1"
  local domain_dir="$2"
  local pa11y_outfile="${domain_dir}/audit_accessibility.json"

  echo "  -> Running pa11y..."
  pa11y -r json --include-notices --include-warnings -s WCAG2AAA "$url" >"$pa11y_outfile" || true
}
