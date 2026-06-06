#!/usr/bin/env bash

_jq_safe() {
  local result
  result=$(jq "$@" 2>/dev/null) || { echo 'null'; return 0; }
  printf '%s' "$result"
}

run_report() {
  local domain_dir="$1"
  local url="$2"
  local report_mode="${3:-focused}"
  local output_format="${4:-json}"

  local audited_at
  audited_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Determine which files to produce
  local do_json="false"
  local do_md="false"
  [[ "$output_format" == "json" || "$output_format" == "both" ]] && do_json="true"
  [[ "$output_format" == "markdown" || "$output_format" == "both" ]] && do_md="true"

  # --- Read inputs defensively ---
  local f_mobile="${domain_dir}/audit_general_mobile.json"
  local f_desktop="${domain_dir}/audit_general_desktop.json"
  local f_a11y="${domain_dir}/audit_accessibility.json"
  local f_sec="${domain_dir}/audit_security_headers.json"
  local f_csp="${domain_dir}/audit_csp.json"
  local f_html="${domain_dir}/audit_html.json"

  # --- JSON format detection (PSI vs Lighthouse CLI) ---
  local has_lh="false"
  if [[ -f "$f_mobile" && -s "$f_mobile" ]]; then
    has_lh=$(_jq_safe -r 'if has("lighthouseResult") then "true" else "false" end' "$f_mobile")
  fi

  local lh_prefix=""
  [[ "$has_lh" == "true" ]] && lh_prefix=".lighthouseResult"

  # --- Score extraction helpers ---
  _get_score() {
    local f="$1"
    local cat="$2"
    [[ -f "$f" && -s "$f" ]] || { printf 'null'; return 0; }
    _jq_safe -r "${lh_prefix}.categories.${cat}.score * 100 | floor / 100" "$f"
  }

  _get_metric() {
    local f="$1"
    local metric="$2"
    [[ -f "$f" && -s "$f" ]] || { printf 'null'; return 0; }
    _jq_safe -r "${lh_prefix}.audits.${metric}.numericValue" "$f"
  }

  # --- Extract scores ---
  local mobile_perf mobile_a11y mobile_seo mobile_bp
  mobile_perf=$(_get_score "$f_mobile" "performance")
  mobile_a11y=$(_get_score "$f_mobile" "accessibility")
  mobile_seo=$(_get_score "$f_mobile" "seo")
  mobile_bp=$(_get_score "$f_mobile" "best-practices")

  local desktop_perf desktop_a11y desktop_seo desktop_bp
  desktop_perf=$(_get_score "$f_desktop" "performance")
  desktop_a11y=$(_get_score "$f_desktop" "accessibility")
  desktop_seo=$(_get_score "$f_desktop" "seo")
  desktop_bp=$(_get_score "$f_desktop" "best-practices")

  # --- Extract metrics ---
  local mlcp mtbt mcls mfcp msi dlcp dtbt dcls dfcp dsi
  mlcp=$(_get_metric "$f_mobile" "largest-contentful-paint")
  mtbt=$(_get_metric "$f_mobile" "total-blocking-time")
  mcls=$(_get_metric "$f_mobile" "cumulative-layout-shift")
  mfcp=$(_get_metric "$f_mobile" "first-contentful-paint")
  msi=$(_get_metric "$f_mobile" "speed-index")
  dlcp=$(_get_metric "$f_desktop" "largest-contentful-paint")
  dtbt=$(_get_metric "$f_desktop" "total-blocking-time")
  dcls=$(_get_metric "$f_desktop" "cumulative-layout-shift")
  dfcp=$(_get_metric "$f_desktop" "first-contentful-paint")
  dsi=$(_get_metric "$f_desktop" "speed-index")

  # --- Accessibility (pa11y) ---
  local a11y_errors="null" a11y_warnings="null" a11y_notices="null"
  local top_errors="[]"
  if [[ -f "$f_a11y" && -s "$f_a11y" ]]; then
    a11y_errors=$(_jq_safe -r '[.[] | select(.type == "error")] | length' "$f_a11y")
    a11y_warnings=$(_jq_safe -r '[.[] | select(.type == "warning")] | length' "$f_a11y")
    a11y_notices=$(_jq_safe -r '[.[] | select(.type == "notice")] | length' "$f_a11y")
    top_errors=$(_jq_safe '[.[] | select(.type == "error")] | group_by(.code) | map({code: .[0].code, message: .[0].message, count: length}) | sort_by(-.count) | .[0:3]' "$f_a11y")
  fi

  # --- Security headers ---
  local sec_pass="null" sec_warn="null" sec_fail="null"
  local sec_headers_json="[]"
  if [[ -f "$f_sec" && -s "$f_sec" ]]; then
    sec_pass=$(_jq_safe -r '[to_entries[] | select(.value.status == "PASS")] | length' "$f_sec")
    sec_warn=$(_jq_safe -r '[to_entries[] | select(.value.status == "WARN")] | length' "$f_sec")
    sec_fail=$(_jq_safe -r '[to_entries[] | select(.value.status == "FAIL")] | length' "$f_sec")
    sec_headers_json=$(_jq_safe 'to_entries | map({name: .key, status: .value.status, value: .value.value})' "$f_sec")
  fi

  # --- CSP ---
  local csp_present="false"
  local csp_valid="false"
  local csp_data="null"
  if [[ -f "$f_csp" && -s "$f_csp" ]]; then
    local is_no_csp
    is_no_csp=$(_jq_safe -r 'if (has("error") and (.error | startswith("No Content-Security-Policy"))) then "true" else "false" end' "$f_csp")
    if [[ "$is_no_csp" != "true" ]]; then
      local has_data
      has_data=$(_jq_safe -r 'if has("data") then "true" else "false" end' "$f_csp")
      if [[ "$has_data" == "true" ]]; then
        csp_present="true"
        local error_count
        error_count=$(_jq_safe -r '[.data[]? | select(.severity == "error")] | length' "$f_csp")
        if [[ "$error_count" == "0" ]]; then
          csp_valid="true"
        fi
      fi
    fi
    csp_data=$(_jq_safe '.' "$f_csp")
  fi

  # --- HTML ---
  local html_json="null"
  [[ -f "$f_html" && -s "$f_html" ]] && html_json=$(_jq_safe '.' "$f_html")

  # =========================================================
  # Output 1: summary.json
  # =========================================================
  if [[ "$do_json" == "true" ]]; then
    local summary_file="${domain_dir}/summary.json"

    # Build sections
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
    if [[ "$csp_present" != "false" || -f "$f_csp" ]]; then
      csp_summary="{\"present\": $csp_present, \"valid\": $csp_valid}"
    fi

    cat >"$summary_file" <<SUMMARY
{
  "url": "$url",
  "audited_at": "$audited_at",
  "scores": $scores_json,
  "metrics": $metrics_json,
  "accessibility_issues": $a11y_json,
  "security_headers": $sec_summary,
  "csp": $csp_summary,
  "html": $html_json
}
SUMMARY
  fi

  # =========================================================
  # Output 2: report.md
  # =========================================================
  if [[ "$do_md" == "true" ]]; then
    local report_file="${domain_dir}/report.md"

    {
      echo "# Audit Report — $url"
      echo ""
      echo "**Audited at:** $audited_at"
      echo ""

      # --- Section 1: Performance ---
      if [[ "$mobile_perf" != "null" || "$desktop_perf" != "null" ]]; then
        echo "## Performance"
        echo ""

        _print_perf_score() {
          local label="$1"
          local perf="$2"
          local a11y="$3"
          local seo="$4"
          local bp="$5"
          if [[ "$perf" != "null" ]]; then
            local perf_pct
            perf_pct=$(printf '%.0f' "$(echo "$perf * 100" | bc -l 2>/dev/null || echo 0)")
            echo "- **$label:** Performance ${perf_pct}/100, Accessibility $a11y, SEO $seo, Best Practices $bp"
          fi
        }

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
          local mtbt_val
          mtbt_val=$(echo "$mtbt" | sed 's/null/0/' 2>/dev/null || echo 0)
          if [[ "$mtbt_val" != "null" && "${mtbt_val%.*}" -lt 600 ]] 2>/dev/null; then
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
      fi

      # --- Section 2: Accessibility ---
      if [[ "$a11y_errors" != "null" ]]; then
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
          # Output top errors as a markdown list from JSON
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
      fi

      # --- Section 3: SEO & Structure ---
      local seo_score="null"
      [[ "$mobile_seo" != "null" ]] && seo_score="$mobile_seo"
      local has_html_data="false"
      [[ "$html_json" != "null" ]] && has_html_data="true"

      if [[ "$seo_score" != "null" || "$has_html_data" == "true" ]]; then
        echo "## SEO & Structure"
        echo ""

        if [[ "$seo_score" != "null" ]]; then
          echo "- **SEO score:** $seo_score"
        fi

        if [[ "$has_html_data" == "true" ]]; then
          echo ""
          local title_present
          title_present=$(echo "$html_json" | jq -r '.title_present // false' 2>/dev/null)
          local meta_desc_present
          meta_desc_present=$(echo "$html_json" | jq -r '.meta_description_present // false' 2>/dev/null)
          local h1_count
          h1_count=$(echo "$html_json" | jq -r '.h1_count // 0' 2>/dev/null)
          local lang_present
          lang_present=$(echo "$html_json" | jq -r '.lang_present // false' 2>/dev/null)
          local canonical_present
          canonical_present=$(echo "$html_json" | jq -r '.canonical_present // false' 2>/dev/null)
          local charset_present
          charset_present=$(echo "$html_json" | jq -r '.charset_present // false' 2>/dev/null)
          local robots_present
          robots_present=$(echo "$html_json" | jq -r '.meta_robots_present // false' 2>/dev/null)
          local robots_value
          robots_value=$(echo "$html_json" | jq -r '.meta_robots_value // ""' 2>/dev/null)
          local ogt_present
          ogt_present=$(echo "$html_json" | jq -r '.og_title_present // false' 2>/dev/null)
          local ogd_present
          ogd_present=$(echo "$html_json" | jq -r '.og_description_present // false' 2>/dev/null)
          local ogi_present
          ogi_present=$(echo "$html_json" | jq -r '.og_image_present // false' 2>/dev/null)
          local sd_present
          sd_present=$(echo "$html_json" | jq -r '.structured_data_present // false' 2>/dev/null)
          local img_alt
          img_alt=$(echo "$html_json" | jq -r '.images_missing_alt_count // 0' 2>/dev/null)

          local issues_found="false"

          if [[ "$title_present" != "true" ]]; then
            echo "- Missing `<title>` tag"
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
            echo "- Missing `lang` attribute on `<html>`"
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

          # OG tag gaps
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
            local title_val
            title_val=$(echo "$html_json" | jq -r '.title_value // ""' 2>/dev/null)
            local lang_val
            lang_val=$(echo "$html_json" | jq -r '.lang_value // ""' 2>/dev/null)
            local canon_val
            canon_val=$(echo "$html_json" | jq -r '.canonical_value // ""' 2>/dev/null)
            local title_len
            title_len=$(echo "$html_json" | jq -r '.title_length // 0' 2>/dev/null)
            local meta_desc_len
            meta_desc_len=$(echo "$html_json" | jq -r '.meta_description_length // 0' 2>/dev/null)
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
      fi

      # --- Section 4: Security ---
      local has_sec="false"
      [[ "$sec_pass" != "null" ]] && has_sec="true"

      if [[ "$has_sec" == "true" || -f "$f_csp" ]]; then
        echo "## Security"
        echo ""

        if [[ "$has_sec" == "true" ]]; then
          echo "| Header | Status | Value |"
          echo "|--------|--------|-------|"
          echo "$sec_headers_json" | jq -r '.[] | "| \(.name) | \(.status) | \(.value) |"' 2>/dev/null || true
          echo ""
        fi

        if [[ -f "$f_csp" ]]; then
          echo "**Content Security Policy:**"
          if [[ "$csp_present" == "true" ]]; then
            echo "- Present"
            echo "- Valid: $csp_valid"
            if [[ "$csp_valid" == "false" ]]; then
              local first_error
              first_error=$(jq -r '[.data[]? | select(.severity == "error")] | .[0].message // "unknown"' "$f_csp" 2>/dev/null || echo "unknown")
              echo "- First violation: $first_error"
            fi
          else
            echo "- No CSP found"
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
      fi
    } >"$report_file"
  fi
}
