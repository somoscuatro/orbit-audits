#!/usr/bin/env bash

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
  local csp_outfile="${domain_dir}/audit_csp.json"

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
