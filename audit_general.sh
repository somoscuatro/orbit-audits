#!/usr/bin/env bash

readonly LH_CATEGORIES=("accessibility" "best-practices" "performance" "seo")

run_general_audit() {
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
