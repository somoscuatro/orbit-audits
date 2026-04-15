#!/usr/bin/env bash

set -euo pipefail

# --- Helper Functions ---

print_help() {
  echo "Usage: $(basename "$0") [options] <urls_file> [audit_type]"
  echo ""
  echo "Arguments:"
  echo "  <urls_file>  Path to a text file containing a list of URLs to audit (one per line)."
  echo "  [audit_type] Optional. Which audit to run. Default is 'all'."
  echo "               Allowed values: all, general, accessibility, csp, security"
  echo ""
  echo "Options:"
  echo "  -h, --help       Show this help message and exit."
  echo "  --lighthouse     Use Lighthouse CLI instead of Google PageSpeed API for the general audit."
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Parse options
USE_LIGHTHOUSE=false
while [[ "${1:-}" == --* ]]; do
  case "$1" in
  --lighthouse)
    USE_LIGHTHOUSE=true
    shift
    ;;
  *)
    echo "Error: Unknown option '$1'" >&2
    exit 1
    ;;
  esac
done

# Configuration
readonly URLS_FILE="$1"
readonly AUDIT_TYPE="${2:-all}"
readonly OUT_DIR="./audits_results"

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

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Audit Functions ---

source "${SCRIPT_DIR}/audit_accessibility.sh"
source "${SCRIPT_DIR}/audit_csp.sh"
source "${SCRIPT_DIR}/audit_security_headers.sh"

# Temporary files registry for cleanup on exit/interrupt
TMP_FILES=()

cleanup() {
  for f in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do
    rm -f "$f"
  done
}

trap cleanup EXIT INT TERM

process_url() {
  local url="$1"
  local domain_safe
  domain_safe=$(domain_to_filename "$url")
  local domain_dir="${OUT_DIR}/${domain_safe}"

  echo "Processing: $url"

  # Create the output directory for this domain
  mkdir -p "$domain_dir"

  # Fetch headers and body ONCE to share across audits that need them (csp, security)
  local tmp_headers=""
  local tmp_body=""

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "csp" || "$AUDIT_TYPE" == "security" ]]; then
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    TMP_FILES+=("$tmp_headers" "$tmp_body")
    curl -sL --max-time 30 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)" -D "$tmp_headers" "$url" >"$tmp_body" || true
  fi

  # Run selected audits based on AUDIT_TYPE parameter
  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "general" ]]; then
    local fallback_to_lighthouse="$USE_LIGHTHOUSE"

    if [[ "$fallback_to_lighthouse" != true ]]; then
      local curl_out status_code content_type
      curl_out=$(curl -sL -o /dev/null -w "%{http_code}\n%{content_type}" --max-time 10 "$url" || echo "000")
      status_code=$(echo "$curl_out" | head -n 1)
      content_type=$(echo "$curl_out" | tail -n 1)

      if [[ "$status_code" != "200" || "$content_type" != *"text/html"* ]]; then
        echo "  -> Notice: URL appears to block basic requests (HTTP ${status_code}, Content-Type: ${content_type:-unknown}). Falling back to Lighthouse CLI."
        fallback_to_lighthouse=true
      fi
    fi

    if [[ "$fallback_to_lighthouse" == true ]]; then
      source "${SCRIPT_DIR}/audit_general_lighthouse.sh"
    else
      source "${SCRIPT_DIR}/audit_general_pagespeed.sh"
    fi
    run_general_audit "$url" "$domain_dir"
  fi

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "accessibility" ]]; then
    run_accessibility_audit "$url" "$domain_dir"
  fi

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "csp" ]]; then
    run_csp_audit "$url" "$domain_dir" "$tmp_headers" "$tmp_body"
  fi

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "security" ]]; then
    run_security_headers_audit "$url" "$domain_dir" "$tmp_headers"
  fi

  # Clean up temporary files for this URL
  rm -f "$tmp_headers" "$tmp_body"
  TMP_FILES=()

  echo "  -> Saved all results for $url in $domain_dir"
}

# Verify that required external commands are available
check_dependencies() {
  local missing=()

  # curl is always needed
  command -v curl >/dev/null 2>&1 || missing+=("curl")

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "general" ]]; then
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    if [[ "$USE_LIGHTHOUSE" == true ]]; then
      command -v lighthouse >/dev/null 2>&1 || missing+=("lighthouse")
    fi
  fi

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "accessibility" ]]; then
    command -v pa11y >/dev/null 2>&1 || missing+=("pa11y")
  fi

  if [[ "$AUDIT_TYPE" == "all" || "$AUDIT_TYPE" == "csp" ]]; then
    command -v csp >/dev/null 2>&1 || missing+=("csp")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: Missing required dependencies: ${missing[*]}" >&2
    exit 1
  fi
}

# --- Main Execution ---

main() {
  if [[ ! -f "$URLS_FILE" ]]; then
    echo "Error: File '$URLS_FILE' not found." >&2
    exit 1
  fi

  if [[ ! "$AUDIT_TYPE" =~ ^(all|general|accessibility|csp|security)$ ]]; then
    echo "Error: Invalid audit type '$AUDIT_TYPE'. Allowed values: all, general, accessibility, csp, security." >&2
    exit 1
  fi

  check_dependencies

  while IFS= read -r url; do
    # Ignore empty lines or lines starting with '#'
    [[ -z "${url// /}" || "$url" =~ ^[[:space:]]*# ]] && continue

    process_url "$url"
  done <"$URLS_FILE"
}

# Execute main function
main
