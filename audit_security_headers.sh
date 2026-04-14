#!/usr/bin/env bash

# Checks a single security header and outputs a JSON fragment (without trailing comma)
check_header_audit() {
  local header_name="$1"
  local expected_val="${2:-}"
  local tmp_headers="$3"

  local val
  val=$(get_http_header "$header_name" "$tmp_headers")

  local present="false"
  local status="FAIL"

  if [[ -n "$val" ]]; then
    present="true"
    if [[ -n "$expected_val" ]]; then
      # Check if the expected value is present in the header (case-insensitive)
      local val_lower
      val_lower=$(echo "$val" | tr '[:upper:]' '[:lower:]')
      local expected_lower
      expected_lower=$(echo "$expected_val" | tr '[:upper:]' '[:lower:]')

      if [[ "$val_lower" == *"$expected_lower"* ]]; then
        status="PASS"
      else
        status="WARN" # Present, but doesn't contain the strictly recommended value
      fi
    else
      status="PASS" # Just needs to be present
    fi
  fi

  # Escape quotes and backslashes for valid JSON
  local safe_val="${val//\\/\\\\}"
  safe_val="${safe_val//\"/\\\"}"

  echo -n "\"$header_name\":{\"present\":$present,\"value\":\"$safe_val\",\"status\":\"$status\"}"
}

run_security_headers_audit() {
  local url="$1"
  local domain_dir="$2"
  local tmp_headers="$3"
  local sec_outfile="${domain_dir}/audit_security_headers.json"

  echo "  -> Running Security Headers audit..."

  # Collect individual header check results, then join with commas
  local fragments=()
  fragments+=("$(check_header_audit "Strict-Transport-Security" "" "$tmp_headers")")
  fragments+=("$(check_header_audit "Content-Security-Policy" "" "$tmp_headers")")
  fragments+=("$(check_header_audit "X-Frame-Options" "" "$tmp_headers")")
  fragments+=("$(check_header_audit "X-Content-Type-Options" "nosniff" "$tmp_headers")")
  fragments+=("$(check_header_audit "Referrer-Policy" "" "$tmp_headers")")
  fragments+=("$(check_header_audit "Permissions-Policy" "" "$tmp_headers")")

  # Join fragments with commas using IFS
  local IFS=","
  echo "{${fragments[*]}}" >"$sec_outfile"
}
