#!/usr/bin/env bash

# Google PageSpeed Insights API categories
readonly -a LH_CATEGORIES=("ACCESSIBILITY" "BEST_PRACTICES" "PERFORMANCE" "SEO") 2>/dev/null || true

run_general_audit() {
  local url="$1"
  local domain_dir="$2"
  local devices=("MOBILE" "DESKTOP")

  # Ensure the URL has a scheme, PageSpeed Insights requires it
  if [[ "$url" != *://* ]]; then
    url="https://${url}"
  fi

  if [[ -z "${GOOGLE_PAGESPEED_API_KEY:-}" ]]; then
    echo "  -> Error: GOOGLE_PAGESPEED_API_KEY environment variable is not set. Skipping general audit." >&2
    return 1
  fi

  for device in "${devices[@]}"; do
    local device_lower
    device_lower=$(echo "$device" | tr '[:upper:]' '[:lower:]')
    
    local general_outfile="${domain_dir}/audit_general_${device_lower}.json"
    echo "  -> Running Google PageSpeed Insights (all categories) for $device..."

    # Build the curl arguments array to pass all categories
    local curl_args=(
      --silent
      --show-error
      --location
      --get
      --data-urlencode "url=${url}"
      --data-urlencode "key=${GOOGLE_PAGESPEED_API_KEY}"
      --data-urlencode "strategy=${device}"
    )

    for cat in "${LH_CATEGORIES[@]}"; do
      curl_args+=(--data-urlencode "category=${cat}")
    done

    # Make the API call, pipe through jq -c to minify JSON for token savings
    curl "${curl_args[@]}" "https://www.googleapis.com/pagespeedonline/v5/runPagespeed" | jq -c . > "$general_outfile" || true
  done
}
