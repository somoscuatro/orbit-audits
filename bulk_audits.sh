#!/usr/bin/env bash

set -euo pipefail

# Configuration
readonly URLS_FILE="${1:-urls_list.txt}"
readonly OUT_DIR="./audits_results"
readonly LH_CATEGORIES=("accessibility" "best-practices" "performance" "seo")

# --- Helper Functions ---

# Function to 'slugify' a URL's domain using pure bash
domain_to_filename() {
  local url="$1"
  # Remove any scheme (http://, https://, etc.)
  local domain="${url#*://}"
  # Remove path, query string, or hash
  domain="${domain%%/*}"
  # Remove www. prefix if it exists
  domain="${domain#www.}"
  # Replace all non-alphanumeric characters with underscores natively
  local domain_safe="${domain//[^a-zA-Z0-9]/_}"

  echo "$domain_safe"
}

# Extracts a specific HTTP header value from a headers file
get_http_header() {
  local header_name="$1"
  local headers_file="$2"

  # grep case-insensitively for the header name, take the first occurrence, strip the key and carriage returns
  grep -i "^${header_name}:" "$headers_file" | head -n 1 | sed -e 's/^[^:]*: *//' | tr -d '\r' || true
}

# --- Audit Functions ---

run_lighthouse() {
  local url="$1"
  local domain_dir="$2"
  local devices=("mobile" "desktop")

  for device in "${devices[@]}"; do
    for cat in "${LH_CATEGORIES[@]}"; do
      local lh_outfile="${domain_dir}/lh_${device}_${cat}.json"
      echo "  -> Running Lighthouse ($cat) for $device..."

      local preset_flag=""
      if [[ "$device" == "desktop" ]]; then
        preset_flag="--preset=desktop"
      fi

      # Use npx lighthouse to ensure it runs if installed locally, or just lighthouse if global.
      # For now relying on `lighthouse` being in PATH as requested.
      lighthouse "$url" --output-path="$lh_outfile" --only-categories "$cat" --output json $preset_flag --disable-full-page-screenshot || true
    done
  done
}

run_pa11y() {
  local url="$1"
  local domain_dir="$2"
  local pa11y_outfile="${domain_dir}/p11y_accessibility.json"

  echo "  -> Running pa11y..."
  pa11y -r json --include-notices --include-warnings -s WCAG2AAA "$url" >"$pa11y_outfile" || true
}

extract_csp() {
  local tmp_headers="$1"
  local tmp_body="$2"
  local csp_content=""

  # Try to find the CSP in the HTTP headers
  csp_content=$(get_http_header "Content-Security-Policy" "$tmp_headers")

  # Fallback to report-only if strict CSP is not found
  if [[ -z "$csp_content" ]]; then
    csp_content=$(get_http_header "Content-Security-Policy-Report-Only" "$tmp_headers")
  fi

  # If not found in headers, check for a <meta http-equiv="Content-Security-Policy" content="..."> tag in the HTML body
  if [[ -z "$csp_content" ]]; then
    csp_content=$(grep -io '<meta[^>]*content-security-policy[^>]*>' "$tmp_body" |
      sed -n -E -e 's/.*content="([^"]*)".*/\1/pi' -e "s/.*content='([^']*)'.*/\1/pi" | head -n 1 || true)
  fi

  echo "$csp_content"
}

run_csp_audit() {
  local url="$1"
  local domain_dir="$2"
  local tmp_headers="$3"
  local tmp_body="$4"
  local csp_outfile="${domain_dir}/csp_evaluator.json"

  echo "  -> Running csp validate..."

  local csp_content
  csp_content=$(extract_csp "$tmp_headers" "$tmp_body")

  if [[ -n "$csp_content" ]]; then
    # Pass the extracted content to 'csp validate' and catch potential non-zero exit codes if the CSP is invalid
    csp validate "$csp_content" --output-format=json-pretty >"$csp_outfile" || true
  else
    echo "  -> No CSP header or meta tag found for $url"
    echo '{ "error": "No Content-Security-Policy found in headers or meta tags" }' >"$csp_outfile"
  fi
}

# Helper to extract header value, determine pass/fail, and output JSON fragment
check_header_audit() {
  local header_name="$1"
  local expected_val="${2:-}"
  local is_last="${3:-false}"
  local tmp_headers="$4"

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

  echo "  \"$header_name\": {"
  echo "    \"present\": $present,"
  echo "    \"value\": \"$safe_val\","
  echo "    \"status\": \"$status\""
  if [[ "$is_last" == "true" ]]; then
    echo "  }"
  else
    echo "  },"
  fi
}

run_security_headers_audit() {
  local url="$1"
  local domain_dir="$2"
  local tmp_headers="$3"
  local sec_outfile="${domain_dir}/security_headers.json"

  echo "  -> Running Security Headers audit..."

  # Build the JSON object
  {
    echo "{"
    check_header_audit "Strict-Transport-Security" "" "false" "$tmp_headers"
    check_header_audit "Content-Security-Policy" "" "false" "$tmp_headers"
    check_header_audit "X-Frame-Options" "" "false" "$tmp_headers"
    check_header_audit "X-Content-Type-Options" "nosniff" "false" "$tmp_headers"
    check_header_audit "Referrer-Policy" "" "false" "$tmp_headers"
    check_header_audit "Permissions-Policy" "" "true" "$tmp_headers"
    echo "}"
  } >"$sec_outfile"
}

process_url() {
  local url="$1"
  local domain_safe
  domain_safe=$(domain_to_filename "$url")
  local domain_dir="${OUT_DIR}/${domain_safe}"

  echo "Processing: $url"

  # Create the output directory for this domain
  mkdir -p "$domain_dir"

  # Fetch headers and body ONCE to share across multiple audits
  local tmp_headers
  local tmp_body
  tmp_headers=$(mktemp)
  tmp_body=$(mktemp)
  curl -sL --max-time 30 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)" -D "$tmp_headers" "$url" >"$tmp_body" || true

  # Note: You can comment out specific audits below to speed up testing
  run_lighthouse "$url" "$domain_dir"
  run_pa11y "$url" "$domain_dir"
  run_csp_audit "$url" "$domain_dir" "$tmp_headers" "$tmp_body"
  run_security_headers_audit "$url" "$domain_dir" "$tmp_headers"

  # Clean up temporary files
  rm -f "$tmp_headers" "$tmp_body"

  echo "  -> Saved all results for $url in $domain_dir"
}

# --- Main Execution ---

main() {
  if [[ ! -f "$URLS_FILE" ]]; then
    echo "Error: File '$URLS_FILE' not found." >&2
    exit 1
  fi

  while IFS= read -r url; do
    # Ignore empty lines or lines starting with '#'
    [[ -z "${url// /}" || "$url" =~ ^[[:space:]]*# ]] && continue

    process_url "$url"
  done <"$URLS_FILE"
}

# Execute main function
main
