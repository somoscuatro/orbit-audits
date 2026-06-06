#!/usr/bin/env bash

_jq_safe() {
  local result
  result=$(jq "$@" 2>/dev/null) || { echo 'null'; return 0; }
  printf '%s' "$result"
}

# Extract all HTML audit fields in a single jq call. Outputs TSV.
# Caveat: fields containing literal tabs are rare in HTML metadata but
# would silently misparse the remaining columns.
# SYNC: field array here must match IFS read variable count in _write_seo_section (18)
_html_extract_all() {
  local json="$1"
  [[ -s "$json" ]] || return 0
  local tsv
  tsv=$(jq -r '
    [
      (.title_present                // false),
      (.meta_description_present     // false),
      (.h1_count                     // 0),
      (.lang_present                 // false),
      (.canonical_present            // false),
      (.charset_present              // false),
      (.meta_robots_present          // false),
      (.meta_robots_value            // ""),
      (.og_title_present             // false),
      (.og_description_present       // false),
      (.og_image_present             // false),
      (.structured_data_present      // false),
      (.images_missing_alt_count     // 0),
      (.title_value                  // ""),
      (.lang_value                   // ""),
      (.canonical_value              // ""),
      (.title_length                 // 0),
      (.meta_description_length      // 0)
    ] | @tsv
  ' "$json" 2>/dev/null) || return 0

  local field_count
  field_count=$(printf '%s' "$tsv" | awk -F'\t' '{print NF}')
  if [[ "$field_count" != "18" ]]; then
    echo " -> Warning: audit_html.json has $field_count fields, expected 18. Report SEO section may be incorrect." >&2
    return 0
  fi

  printf '%s' "$tsv"
}

_get_score() {
  local f="$1" cat="$2" lh_prefix="$3"
  [[ -f "$f" && -s "$f" ]] || { printf 'null'; return 0; }
  _jq_safe -r "${lh_prefix}.categories[\"${cat}\"].score | (. * 100) | floor" "$f"
}

_get_metric() {
  local f="$1" metric="$2" lh_prefix="$3"
  [[ -f "$f" && -s "$f" ]] || { printf 'null'; return 0; }
  _jq_safe -r "${lh_prefix}.audits.${metric}.numericValue" "$f"
}

_print_perf_score() {
  local label="$1" perf="$2" a11y="$3" seo="$4" bp="$5"
  [[ "$perf" == "null" ]] && return
  local perf_pct
  perf_pct=${perf%.*}
  echo "- **$label:**"
  echo "  - Performance: ${perf_pct}/100"
  echo "  - Accessibility: $a11y"
  echo "  - SEO: $seo"
  echo "  - Best Practices: $bp"
}

# === Report section writers ===

_write_perf_section() {
  local domain_dir="$1" lh_prefix="$2" report_mode="$3"
  local f_mobile="${domain_dir}/audit_general_mobile.json"
  local f_desktop="${domain_dir}/audit_general_desktop.json"

  local mobile_perf
  mobile_perf=$(_get_score "$f_mobile" "performance" "$lh_prefix")
  [[ "$mobile_perf" == "null" ]] && return

  local mobile_a11y mobile_seo mobile_bp
  mobile_a11y=$(_get_score "$f_mobile" "accessibility" "$lh_prefix")
  mobile_seo=$(_get_score "$f_mobile" "seo" "$lh_prefix")
  mobile_bp=$(_get_score "$f_mobile" "best-practices" "$lh_prefix")

  local desktop_perf desktop_a11y desktop_seo desktop_bp
  desktop_perf=$(_get_score "$f_desktop" "performance" "$lh_prefix")
  desktop_a11y=$(_get_score "$f_desktop" "accessibility" "$lh_prefix")
  desktop_seo=$(_get_score "$f_desktop" "seo" "$lh_prefix")
  desktop_bp=$(_get_score "$f_desktop" "best-practices" "$lh_prefix")

  local mlcp mtbt mcls mfcp msi dlcp dtbt dcls dfcp dsi
  mlcp=$(_get_metric "$f_mobile" "largest-contentful-paint" "$lh_prefix")
  mtbt=$(_get_metric "$f_mobile" "total-blocking-time" "$lh_prefix")
  mcls=$(_get_metric "$f_mobile" "cumulative-layout-shift" "$lh_prefix")
  mfcp=$(_get_metric "$f_mobile" "first-contentful-paint" "$lh_prefix")
  msi=$(_get_metric "$f_mobile" "speed-index" "$lh_prefix")
  dlcp=$(_get_metric "$f_desktop" "largest-contentful-paint" "$lh_prefix")
  dtbt=$(_get_metric "$f_desktop" "total-blocking-time" "$lh_prefix")
  dcls=$(_get_metric "$f_desktop" "cumulative-layout-shift" "$lh_prefix")
  dfcp=$(_get_metric "$f_desktop" "first-contentful-paint" "$lh_prefix")
  dsi=$(_get_metric "$f_desktop" "speed-index" "$lh_prefix")

  echo "## Performance"
  echo ""

  _print_perf_score "Mobile" "$mobile_perf" "$mobile_a11y" "$mobile_seo" "$mobile_bp"
  _print_perf_score "Desktop" "$desktop_perf" "$desktop_a11y" "$desktop_seo" "$desktop_bp"

  if [[ "$mlcp" != "null" ]]; then
    echo ""
    echo "### Mobile Metrics"
    echo ""
    [[ "$mlcp" != "null" ]] && echo "- LCP: ${mlcp}ms"
    [[ "$mtbt" != "null" ]] && echo "- TBT: ${mtbt}ms"
    [[ "$mcls" != "null" ]] && echo "- CLS: $mcls"
    if [[ "$report_mode" == "complete" ]]; then
      [[ "$mfcp" != "null" ]] && echo "- FCP: ${mfcp}ms"
      [[ "$msi" != "null" ]] && echo "- Speed Index: ${msi}ms"
    fi
    if [[ "$mtbt" != "null" && "${mtbt%.*}" -lt 600 ]]; then
      echo ""
      echo "> **Note:** Mobile TBT is < 600ms — throttling may be unreliable. Treat these metrics as indicative only."
    fi
  fi

  if [[ "$dlcp" != "null" ]]; then
    echo ""
    echo "### Desktop Metrics"
    echo ""
    [[ "$dlcp" != "null" ]] && echo "- LCP: ${dlcp}ms"
    [[ "$dtbt" != "null" ]] && echo "- TBT: ${dtbt}ms"
    if [[ "$report_mode" == "complete" ]]; then
      [[ "$dfcp" != "null" ]] && echo "- FCP: ${dfcp}ms"
      [[ "$dsi" != "null" ]] && echo "- Speed Index: ${dsi}ms"
      [[ "$dcls" != "null" ]] && echo "- CLS: $dcls"
    fi
  fi
  echo ""
}

_write_a11y_section() {
  local domain_dir="$1" lh_prefix="$2" report_mode="$3"
  local f_a11y="${domain_dir}/audit_accessibility.json"
  local f_mobile="${domain_dir}/audit_general_mobile.json"

  local a11y_errors
  a11y_errors=$(_jq_safe -r '[.[] | select(.type == "error")] | length' "$f_a11y")
  [[ "$a11y_errors" == "null" ]] && return

  local mobile_a11y
  mobile_a11y=$(_get_score "$f_mobile" "accessibility" "$lh_prefix")

  local a11y_warnings a11y_notices top_errors
  a11y_warnings=$(_jq_safe -r '[.[] | select(.type == "warning")] | length' "$f_a11y")
  a11y_notices=$(_jq_safe -r '[.[] | select(.type == "notice")] | length' "$f_a11y")
  top_errors=$(_jq_safe '[.[] | select(.type == "error")] | group_by(.code) | map({code: .[0].code, message: .[0].message, count: length}) | sort_by(-.count) | .[0:3]' "$f_a11y")

  echo "## Accessibility"
  echo ""
  if [[ "$mobile_a11y" != "null" ]]; then
    echo "- **Lighthouse accessibility score:** $mobile_a11y"
  fi
  echo "- **Pa11y errors:** $a11y_errors"
  [[ "$report_mode" == "complete" ]] && echo "- **Pa11y warnings:** $a11y_warnings"
  [[ "$report_mode" == "complete" ]] && echo "- **Pa11y notices:** $a11y_notices"

  if [[ "$a11y_errors" != "0" ]]; then
    echo ""
    echo "### Top Pa11y Errors"
    echo ""
    echo "$top_errors" | jq -r '.[] | "- **\(.code):** \(.message) (\(.count) occurrences)"' 2>/dev/null || true
  fi

  if [[ "$report_mode" == "complete" ]]; then
    local all_pa11y
    all_pa11y=$(jq -r '.[] | "- [\(.type)] **\(.code):** \(.message)"' "$f_a11y" 2>/dev/null || true)
    if [[ -n "$all_pa11y" ]]; then
      echo ""
      echo "### All Pa11y Findings"
      echo ""
      echo "$all_pa11y"
    fi
  fi
  echo ""
}

_write_seo_section() {
  local domain_dir="$1" lh_prefix="$2" report_mode="$3"
  local f_html="${domain_dir}/audit_html.json"
  local f_mobile="${domain_dir}/audit_general_mobile.json"

  local seo_score="null"
  [[ -f "$f_mobile" && -s "$f_mobile" ]] && seo_score=$(_get_score "$f_mobile" "seo" "$lh_prefix")

  local has_html="false"
  [[ -f "$f_html" && -s "$f_html" ]] && has_html="true"

  [[ "$seo_score" == "null" && "$has_html" != "true" ]] && return

  echo "## SEO & Structure"
  echo ""

  if [[ "$seo_score" != "null" ]]; then
    echo "- **SEO score:** $seo_score"
  fi

  if [[ "$has_html" == "true" ]]; then
    echo ""

    local title_present meta_desc_present h1_count lang_present
    local canonical_present charset_present robots_present robots_value
    local ogt_present ogd_present ogi_present sd_present img_alt
    local title_val lang_val canon_val title_len meta_desc_len

    # SYNC: variable count here must match _html_extract_all field array (18)
    IFS=$'\t' read -r title_present meta_desc_present h1_count lang_present \
      canonical_present charset_present robots_present robots_value \
      ogt_present ogd_present ogi_present sd_present img_alt \
      title_val lang_val canon_val title_len meta_desc_len \
      <<< "$(_html_extract_all "$f_html")"

    local issues_found="false"

    if [[ "$title_present" != "true" ]]; then
      echo "- Missing \`<title>\` tag"
      issues_found="true"
    fi
    if [[ "$meta_desc_present" != "true" ]]; then
      echo "- Missing meta description"
      issues_found="true"
    fi
    if [[ "$h1_count" != "1" ]]; then
      echo "- H1 count is $h1_count (should be 1)"
      issues_found="true"
    fi
    if [[ "$canonical_present" != "true" ]]; then
      echo "- Missing canonical link"
      issues_found="true"
    fi
    if [[ "$lang_present" != "true" ]]; then
      echo "- Missing \`lang\` attribute on \`<html>\`"
      issues_found="true"
    fi
    if [[ "$charset_present" != "true" ]]; then
      echo "- Missing charset meta tag"
      issues_found="true"
    fi
    if [[ "$robots_present" == "true" && "$robots_value" == *"noindex"* ]]; then
      echo "- Page is set to noindex (not searchable)"
      issues_found="true"
    fi
    if [[ "$img_alt" != "0" ]]; then
      echo "- $img_alt image(s) missing alt text"
      issues_found="true"
    fi

    local og_missing=()
    [[ "$ogt_present" != "true" ]] && og_missing+=("og:title")
    [[ "$ogd_present" != "true" ]] && og_missing+=("og:description")
    [[ "$ogi_present" != "true" ]] && og_missing+=("og:image")
    if [[ ${#og_missing[@]} -gt 0 ]]; then
      echo "- Missing Open Graph tags: ${og_missing[*]}"
      issues_found="true"
    fi

    if [[ "$sd_present" != "true" ]]; then
      echo "- No structured data (JSON-LD) found"
      issues_found="true"
    fi

    if [[ "$issues_found" == "false" ]]; then
      echo "All HTML structure checks passed."
    fi

    if [[ "$report_mode" == "complete" ]]; then
      echo ""
      echo "### Complete HTML Fields"
      echo ""
      echo "- Title: \"$title_val\" ($title_len chars)"
      echo "- Meta description length: $meta_desc_len chars"
      echo "- H1 count: $h1_count"
      echo "- Lang: $lang_val"
      echo "- Canonical: $canon_val"
      echo "- Charset present: $charset_present"
      echo "- Meta robots present: $robots_present ($robots_value)"
      echo "- OG title: $ogt_present"
      echo "- OG description: $ogd_present"
      echo "- OG image: $ogi_present"
      echo "- Structured data: $sd_present"
      echo "- Images missing alt: $img_alt"
    fi
  fi
  echo ""
}

_write_security_section() {
  local domain_dir="$1" report_mode="$2"
  local f_sec="${domain_dir}/audit_security_headers.json"
  local f_csp="${domain_dir}/audit_csp.json"

  local sec_pass="null"
  local sec_headers_json="[]"
  if [[ -f "$f_sec" && -s "$f_sec" ]]; then
    sec_pass=$(_jq_safe -r '[to_entries[] | select(.value.status == "PASS")] | length' "$f_sec")
    sec_headers_json=$(_jq_safe 'to_entries | map({name: .key, status: .value.status, value: .value.value})' "$f_sec")
  fi

  local has_sec="false"
  [[ "$sec_pass" != "null" ]] && has_sec="true"

  [[ "$has_sec" != "true" && ! -f "$f_csp" ]] && return

  echo "## Security"
  echo ""

  if [[ "$has_sec" == "true" ]]; then
    echo "| Header | Status | Value |"
    echo "|--------|--------|-------|"
    echo "$sec_headers_json" | jq -r '.[] | "| \(.name) | \(.status) | \(.value) |"' 2>/dev/null || true
    echo ""
  fi

  if [[ -f "$f_csp" && -s "$f_csp" ]]; then
    local is_no_csp
    is_no_csp=$(_jq_safe -r 'if type == "object" and has("error") and (.error | startswith("No Content-Security-Policy")) then "true" else "false" end' "$f_csp")

    if [[ "$is_no_csp" == "true" ]]; then
      echo "**Content Security Policy:**"
      echo "- No CSP found"
    else
      local is_array
      is_array=$(_jq_safe -r 'if type == "array" then "true" else "false" end' "$f_csp")
      [[ "$is_array" != "true" ]] && return

      local csp_valid="false"
      local error_count
      # csp validate --output-format=json returns an array of finding objects.
      # Severity scale (csp npm package): 1 = notice, 10 = warning, 20 = error.
      # We treat severity >= 20 as a hard error (CSP invalid).
      error_count=$(_jq_safe -r '[.[]? | select(.severity >= 20)] | length' "$f_csp")
      [[ "$error_count" == "0" ]] && csp_valid="true"

      echo "**Content Security Policy:**"
      echo "- Present"
      echo "- Valid: $csp_valid"
      if [[ "$csp_valid" == "false" ]]; then
        local first_error
        first_error=$(jq -r '[.[]? | select(.severity == "error")] | .[0].message // "unknown"' "$f_csp" 2>/dev/null || echo "unknown")
        echo "- First violation: $first_error"
      fi
    fi

    if [[ "$report_mode" == "complete" ]]; then
      echo ""
      echo "### Full CSP Output"
      echo ""
      echo '```json'
      cat "$f_csp" 2>/dev/null || echo '{"error": "cannot read CSP file"}'
      echo ""
      echo '```'
    fi
    echo ""
  fi
}

run_report() {
  local domain_dir="$1"
  local url="$2"
  local report_mode="${3:-focused}"

  local audited_at
  audited_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local f_mobile="${domain_dir}/audit_general_mobile.json"
  local f_desktop="${domain_dir}/audit_general_desktop.json"
  local f_a11y="${domain_dir}/audit_accessibility.json"
  local f_sec="${domain_dir}/audit_security_headers.json"
  local f_csp="${domain_dir}/audit_csp.json"
  local f_html="${domain_dir}/audit_html.json"

  # JSON format detection (PSI vs Lighthouse CLI)
  local has_lh="false"
  if [[ -f "$f_mobile" && -s "$f_mobile" ]]; then
    has_lh=$(_jq_safe -r 'if has("lighthouseResult") then "true" else "false" end' "$f_mobile")
  fi
  local lh_prefix=""
  [[ "$has_lh" == "true" ]] && lh_prefix=".lighthouseResult"

  # Extract scores for summary.json
  local mobile_perf mobile_a11y mobile_seo mobile_bp
  mobile_perf=$(_get_score "$f_mobile" "performance" "$lh_prefix")
  mobile_a11y=$(_get_score "$f_mobile" "accessibility" "$lh_prefix")
  mobile_seo=$(_get_score "$f_mobile" "seo" "$lh_prefix")
  mobile_bp=$(_get_score "$f_mobile" "best-practices" "$lh_prefix")

  local desktop_perf desktop_a11y desktop_seo desktop_bp
  desktop_perf=$(_get_score "$f_desktop" "performance" "$lh_prefix")
  desktop_a11y=$(_get_score "$f_desktop" "accessibility" "$lh_prefix")
  desktop_seo=$(_get_score "$f_desktop" "seo" "$lh_prefix")
  desktop_bp=$(_get_score "$f_desktop" "best-practices" "$lh_prefix")

  local mlcp mtbt mcls mfcp msi dlcp dtbt dcls dfcp dsi
  mlcp=$(_get_metric "$f_mobile" "largest-contentful-paint" "$lh_prefix")
  mtbt=$(_get_metric "$f_mobile" "total-blocking-time" "$lh_prefix")
  mcls=$(_get_metric "$f_mobile" "cumulative-layout-shift" "$lh_prefix")
  mfcp=$(_get_metric "$f_mobile" "first-contentful-paint" "$lh_prefix")
  msi=$(_get_metric "$f_mobile" "speed-index" "$lh_prefix")
  dlcp=$(_get_metric "$f_desktop" "largest-contentful-paint" "$lh_prefix")
  dtbt=$(_get_metric "$f_desktop" "total-blocking-time" "$lh_prefix")
  dcls=$(_get_metric "$f_desktop" "cumulative-layout-shift" "$lh_prefix")
  dfcp=$(_get_metric "$f_desktop" "first-contentful-paint" "$lh_prefix")
  dsi=$(_get_metric "$f_desktop" "speed-index" "$lh_prefix")

  # Accessibility (pa11y)
  local a11y_errors="null" a11y_warnings="null" a11y_notices="null"
  if [[ -f "$f_a11y" && -s "$f_a11y" ]]; then
    a11y_errors=$(_jq_safe -r '[.[] | select(.type == "error")] | length' "$f_a11y")
    a11y_warnings=$(_jq_safe -r '[.[] | select(.type == "warning")] | length' "$f_a11y")
    a11y_notices=$(_jq_safe -r '[.[] | select(.type == "notice")] | length' "$f_a11y")
  fi

  # Security headers
  local sec_pass="null" sec_warn="null" sec_fail="null"
  if [[ -f "$f_sec" && -s "$f_sec" ]]; then
    sec_pass=$(_jq_safe -r '[to_entries[] | select(.value.status == "PASS")] | length' "$f_sec")
    sec_warn=$(_jq_safe -r '[to_entries[] | select(.value.status == "WARN")] | length' "$f_sec")
    sec_fail=$(_jq_safe -r '[to_entries[] | select(.value.status == "FAIL")] | length' "$f_sec")
  fi

  # CSP
  local csp_present="false" csp_valid="false"
  if [[ -f "$f_csp" && -s "$f_csp" ]]; then
    local is_no_csp
    is_no_csp=$(_jq_safe -r 'if type == "object" and has("error") and (.error | startswith("No Content-Security-Policy")) then "true" else "false" end' "$f_csp")
    if [[ "$is_no_csp" != "true" ]]; then
      local is_array
      is_array=$(_jq_safe -r 'if type == "array" then "true" else "false" end' "$f_csp")
      if [[ "$is_array" == "true" ]]; then
        csp_present="true"
        local error_count
        # csp validate --output-format=json returns an array of finding objects.
        # Severity scale (csp npm package): 1 = notice, 10 = warning, 20 = error.
        # We treat severity >= 20 as a hard error (CSP invalid).
        error_count=$(_jq_safe -r '[.[]? | select(.severity >= 20)] | length' "$f_csp")
        [[ "$error_count" == "0" ]] && csp_valid="true"
      fi
    fi
  fi

  # HTML
  local html_json="null"
  [[ -f "$f_html" && -s "$f_html" ]] && html_json=$(_jq_safe '.' "$f_html")

  # --- summary.json ---
  local summary_file="${domain_dir}/summary.json"

    local scores_json="null"
    if [[ "$mobile_perf" != "null" || "$desktop_perf" != "null" ]]; then
      scores_json=$(cat <<SCORES
{
    "mobile": {
      "performance": $mobile_perf,
      "accessibility": $mobile_a11y,
      "seo": $mobile_seo,
      "best_practices": $mobile_bp
    },
    "desktop": {
      "performance": $desktop_perf,
      "accessibility": $desktop_a11y,
      "seo": $desktop_seo,
      "best_practices": $desktop_bp
    }
  }
SCORES
)
    fi

    local metrics_json="null"
    if [[ "$mlcp" != "null" || "$dlcp" != "null" ]]; then
      metrics_json=$(cat <<METRICS
{
    "mobile": {
      "lcp_ms": ${mlcp:-null},
      "tbt_ms": ${mtbt:-null},
      "cls": ${mcls:-null},
      "fcp_ms": ${mfcp:-null},
      "si_ms": ${msi:-null}
    },
    "desktop": {
      "lcp_ms": ${dlcp:-null},
      "tbt_ms": ${dtbt:-null},
      "cls": ${dcls:-null},
      "fcp_ms": ${dfcp:-null},
      "si_ms": ${dsi:-null}
    }
  }
METRICS
)
    fi

    local a11y_json="null"
    [[ "$a11y_errors" != "null" ]] && a11y_json="{\"errors\": $a11y_errors, \"warnings\": $a11y_warnings, \"notices\": $a11y_notices}"

    local sec_summary="null"
    if [[ "$sec_pass" != "null" ]]; then
      sec_summary="{\"pass\": $sec_pass, \"warn\": $sec_warn, \"fail\": $sec_fail}"
    fi

    local csp_summary="null"
    if [[ -f "$f_csp" ]]; then
      csp_summary="{\"present\": $csp_present, \"valid\": $csp_valid}"
    fi

    jq -n \
      --arg     url                  "$url" \
      --arg     audited_at           "$audited_at" \
      --argjson scores               "${scores_json:-null}" \
      --argjson metrics              "${metrics_json:-null}" \
      --argjson accessibility_issues "${a11y_json:-null}" \
      --argjson security_headers     "${sec_summary:-null}" \
      --argjson csp                  "${csp_summary:-null}" \
      --argjson html                 "${html_json:-null}" \
      '{
        url:                  $url,
        audited_at:           $audited_at,
        scores:               $scores,
        metrics:              $metrics,
        accessibility_issues: $accessibility_issues,
        security_headers:     $security_headers,
        csp:                  $csp,
        html:                 $html
      }' > "$summary_file"

  # --- report.md ---
  local report_file="${domain_dir}/report.md"
  {
    echo "# Audit Report — $url"
    echo ""
    echo "**Audited at:** $audited_at"
    echo ""

    _write_perf_section "$domain_dir" "$lh_prefix" "$report_mode"
    _write_a11y_section "$domain_dir" "$lh_prefix" "$report_mode"
    _write_seo_section "$domain_dir" "$lh_prefix" "$report_mode"
    _write_security_section "$domain_dir" "$report_mode"
  } >"$report_file"
}
