#!/usr/bin/env bash

# Lighthouse CLI-based general audit (alternative to PageSpeed API version)
# Requires: lighthouse (npm i -g lighthouse), Chrome/Chromium installed

run_general_audit() {
  local url="$1"
  local domain_dir="$2"
  local devices=("mobile" "desktop")

  # Ensure the URL has a scheme, Lighthouse requires it
  if [[ "$url" != *://* ]]; then
    url="https://${url}"
  fi

  if ! command -v lighthouse >/dev/null 2>&1; then
    echo "  -> Error: lighthouse CLI not found. Install with: npm i -g lighthouse" >&2
    return 1
  fi

  for device in "${devices[@]}"; do
    local general_outfile="${domain_dir}/audit_general_${device}.json"
    echo "  -> Running Lighthouse CLI (all categories) for ${device}..."

    # Build base args
    local lh_args=(
      "$url"
      --output=json
      --output-path=stdout
      --quiet
      --chrome-flags="--headless --no-sandbox"
      --only-categories=accessibility,best-practices,performance,seo
      --disable-full-page-screenshot
    )

    # Desktop uses the built-in desktop preset; mobile is the default
    if [[ "$device" == "desktop" ]]; then
      lh_args+=(--preset=desktop)
    fi

    # Run lighthouse, pipe through jq -c to minify JSON for token savings
    if ! lighthouse "${lh_args[@]}" 2>/dev/null | jq -c . >"$general_outfile"; then
      echo "  -> Warning: Lighthouse ${device} audit failed for ${url}" >&2
      rm -f "$general_outfile"
    fi
  done
}
