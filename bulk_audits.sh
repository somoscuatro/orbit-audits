#!/usr/bin/env bash

set -euo pipefail

# --- Helper Functions ---

print_help() {
  echo "Usage: $(basename "$0") [options] <urls_file> [audit_type]"
  echo ""
  echo "Arguments:"
  echo "  <urls_file>  Path to a text file containing a list of URLs to audit (one per line)."
  echo "  [audit_type] Optional. Which audit to run. Default is 'all'."
  echo "               Allowed values: all, general, accessibility, csp, security, html"
  echo ""
  echo "Options:"
  echo "  -h, --help       Show this help message and exit."
  echo "  --lighthouse     Use Lighthouse CLI instead of Google PageSpeed API for the general audit."
  echo "  --report <mode>  Report verbosity. Default: 'focused' (actionable findings only)."
  echo "                   Use 'complete' for all findings including notices and raw values."
  echo "  --format <fmt>   Output format. Default: 'json' (best for AI consumption)."
  echo "                   Allowed: json (summary.json only), markdown (report.md only), both."
}

# Parse options
USE_LIGHTHOUSE=false
URLS_FILE=""
AUDIT_TYPE="all"
REPORT_MODE="focused"
OUTPUT_FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    print_help
    exit 0
    ;;
  --lighthouse)
    USE_LIGHTHOUSE=true
    shift
    ;;
  --report)
    if [[ -z "${2:-}" ]]; then
      echo "Error: --report requires a value: focused or complete" >&2
      exit 1
    fi
    REPORT_MODE="$2"
    shift 2
    ;;
  --format)
    if [[ -z "${2:-}" ]]; then
      echo "Error: --format requires a value: json, markdown, or both" >&2
      exit 1
    fi
    OUTPUT_FORMAT="$2"
    shift 2
    ;;
  -*)
    echo "Error: Unknown option '$1'" >&2
    exit 1
    ;;
  *)
    if [[ -z "$URLS_FILE" ]]; then
      URLS_FILE="$1"
    elif [[ "$AUDIT_TYPE" == "all" ]]; then
      AUDIT_TYPE="$1"
    else
      echo "Error: Unexpected argument '$1'" >&2
      exit 1
    fi
    shift
    ;;
  esac
done

if [[ -z "$URLS_FILE" ]]; then
  print_help
  exit 1
fi

# Configuration
readonly URLS_FILE
readonly AUDIT_TYPE
readonly REPORT_MODE
readonly OUTPUT_FORMAT
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
source "${SCRIPT_DIR}/audit_html.sh"
source "${SCRIPT_DIR}/audit_report.sh"

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

  # Fetch headers and body ONCE to share across ALL audits (DRY principle)
  local tmp_headers tmp_body curl_out status_code content_type
  tmp_headers=$(mktemp)
  tmp_body=$(mktemp)
  TMP_FILES+=("$tmp_headers" "$tmp_body")

  # Use a single curl request to get body, headers, HTTP code, and Content-Type simultaneously
  curl_out=$(curl -sL --max-time 30 --retry 2 --retry-delay 5 \
    -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)" \
    -D "$tmp_headers" \
    -w "%{http_code}\n%{content_type}" \
    -o "$tmp_body" \
    "$url" || echo -e "000\nunknown")

  status_code=$(echo "$curl_out" | head -n 1)
  content_type=$(echo "$curl_out" | tail -n 1)

  # Run selected audits based on AUDIT_TYPE parameter
  if [[ "$AUDIT_TYPE" =~ ^(all|general)$ ]]; then
    local fallback_to_lighthouse="$USE_LIGHTHOUSE"

    if [[ "$fallback_to_lighthouse" != true ]]; then
      if [[ "$status_code" != "200" || "$content_type" != *"text/html"* ]]; then
        if command -v lighthouse >/dev/null 2>&1; then
          echo "  -> Notice: URL appears to block basic requests (HTTP ${status_code}, Content-Type: ${content_type:-unknown}). Falling back to Lighthouse CLI."
          fallback_to_lighthouse=true
        else
          echo "  -> Notice: URL blocks basic requests (HTTP ${status_code}), but 'lighthouse' CLI is not installed. Attempting PageSpeed API anyway."
        fi
      fi
    fi

    # Strategy Pattern: Dynamically source the chosen implementation
    if [[ "$fallback_to_lighthouse" == true ]]; then
      source "${SCRIPT_DIR}/audit_general_lighthouse.sh"
      run_general_audit "$url" "$domain_dir"
    else
      source "${SCRIPT_DIR}/audit_general_pagespeed.sh"
      run_general_audit "$url" "$domain_dir"

      # Since PageSpeed runs on Google Datacenter IPs, it often gets blocked (e.g. 503) 
      # by sites even if your local laptop's `curl` passed perfectly fine.
      # So we MUST verify the actual JSON output from PageSpeed API.
      local ps_failed=false
      for device in mobile desktop; do
        local f="${domain_dir}/audit_general_${device}.json"
        # If the file is missing/empty, or jq parses out an `.error` object
        if [[ ! -s "$f" ]] || grep -q '"error":' "$f"; then
          ps_failed=true
          break
        fi
      done

      if [[ "$ps_failed" == true ]]; then
        if command -v lighthouse >/dev/null 2>&1; then
          echo "  -> Warning: PageSpeed API returned an error (likely blocked Google IP). Retrying locally with Lighthouse CLI..."
          source "${SCRIPT_DIR}/audit_general_lighthouse.sh"
          run_general_audit "$url" "$domain_dir"
        else
          echo "  -> Warning: PageSpeed API returned an error, but 'lighthouse' CLI is not installed. Cannot retry locally."
        fi
      fi
    fi
  fi

  if [[ "$AUDIT_TYPE" =~ ^(all|accessibility)$ ]]; then
    run_accessibility_audit "$url" "$domain_dir"
  fi

  if [[ "$AUDIT_TYPE" =~ ^(all|csp)$ ]]; then
    run_csp_audit "$url" "$domain_dir" "$tmp_headers" "$tmp_body"
  fi

  if [[ "$AUDIT_TYPE" =~ ^(all|security)$ ]]; then
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

  # jq is always needed (general audits + report generation)
  command -v jq >/dev/null 2>&1 || missing+=("jq")

  if [[ "$AUDIT_TYPE" =~ ^(all|general)$ ]]; then
    # Note: lighthouse might be needed dynamically during fallback,
    # but we only hard-fail upfront if the user explicitly forced --lighthouse
    if [[ "$USE_LIGHTHOUSE" == true ]]; then
      command -v lighthouse >/dev/null 2>&1 || missing+=("lighthouse")
    fi
  fi

  if [[ "$AUDIT_TYPE" =~ ^(all|accessibility)$ ]]; then
    command -v pa11y >/dev/null 2>&1 || missing+=("pa11y")
  fi

  if [[ "$AUDIT_TYPE" =~ ^(all|csp)$ ]]; then
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

  if [[ ! "$AUDIT_TYPE" =~ ^(all|general|accessibility|csp|security|html)$ ]]; then
    echo "Error: Invalid audit type '$AUDIT_TYPE'. Allowed values: all, general, accessibility, csp, security, html." >&2
    exit 1
  fi

  if [[ ! "$REPORT_MODE" =~ ^(focused|complete)$ ]]; then
    echo "Error: Invalid report mode '$REPORT_MODE'. Allowed values: focused, complete." >&2
    exit 1
  fi

  if [[ ! "$OUTPUT_FORMAT" =~ ^(json|markdown|both)$ ]]; then
    echo "Error: Invalid output format '$OUTPUT_FORMAT'. Allowed values: json, markdown, both." >&2
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
