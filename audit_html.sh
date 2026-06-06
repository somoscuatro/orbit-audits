#!/usr/bin/env bash

is_valid_html_page() {
  local status_code="$1"
  local content_type="$2"
  local tmp_body="$3"

  [[ "$status_code" == "200" ]] || return 1
  [[ "$content_type" == *"text/html"* || "$content_type" == *"application/xhtml+xml"* ]] || return 1
  [[ -s "$tmp_body" ]] || return 1
  return 0
}

# Helper: extract attribute value from a tag line
# Usage: _extract_attr <attr_name> <grep_output>
_extract_attr() {
  local attr="$1"
  local line="$2"
  echo "$line" | grep -Eoi "${attr}=[\"']?[^\"'[:space:]>]*" | sed -E "s/${attr}=[\"']?//; s/[\"']$//" | head -1 || true
}

run_html_audit() {
  local tmp_body="$1"
  local domain_dir="$2"
  local html_outfile="${domain_dir}/audit_html.json"

  echo "  -> Running HTML structure audit..."

  local title_present="false"
  local title_value=""
  local title_length=0
  local meta_description_present="false"
  local meta_description_length=0
  local h1_count=0
  local lang_present="false"
  local lang_value=""
  local viewport_present="false"
  local canonical_present="false"
  local canonical_value=""
  local charset_present="false"
  local meta_robots_present="false"
  local meta_robots_value=""
  local og_title_present="false"
  local og_description_present="false"
  local og_image_present="false"
  local structured_data_present="false"
  local images_missing_alt_count=0

  # --- Title ---
  if grep -qi '<title' "$tmp_body"; then
    title_present="true"
    title_value=$(grep -io '<title[^>]*>[^<]*</title>' "$tmp_body" | sed -E 's/<[^>]*>//g' | head -1 || true)
    title_length=${#title_value}
  fi

  # --- Meta description ---
  if grep -Eqi '<meta[^>]*name=["'"'"']?description["'"'"']?' "$tmp_body"; then
    meta_description_present="true"
    local desc_line
    desc_line=$(grep -Ei '<meta[^>]*name=["'"'"']?description["'"'"']?' "$tmp_body" | head -1 || true)
    local desc_content
    desc_content=$(_extract_attr "content" "$desc_line")
    meta_description_length=${#desc_content}
  fi

  # --- H1 count ---
  h1_count=$(grep -io '<h1[[:space:]>]' "$tmp_body" | wc -l | tr -d ' ' || true)

  # --- Lang attribute ---
  if grep -qi '<html[^>]*lang=' "$tmp_body"; then
    lang_present="true"
    lang_value=$(grep -Eio '<html[^>]*lang=["'"'"']?[a-zA-Z-]+' "$tmp_body" | sed -E "s/.*lang=[\"']?//; s/[\"']$//" | head -1 || true)
  fi

  # --- Viewport ---
  if grep -Eqi '<meta[^>]*name=["'"'"']?viewport["'"'"']?' "$tmp_body"; then
    viewport_present="true"
  fi

  # --- Canonical ---
  if grep -Eqi '<link[^>]*rel=["'"'"']?canonical["'"'"']?' "$tmp_body"; then
    canonical_present="true"
    local canon_line
    canon_line=$(grep -Ei '<link[^>]*rel=["'"'"']?canonical["'"'"']?' "$tmp_body" | head -1 || true)
    canonical_value=$(_extract_attr "href" "$canon_line")
  fi

  # --- Charset ---
  if grep -qi '<meta[^>]*charset=' "$tmp_body"; then
    charset_present="true"
  fi

  # --- Meta robots ---
  if grep -Eqi '<meta[^>]*name=["'"'"']?robots["'"'"']?' "$tmp_body"; then
    meta_robots_present="true"
    local robots_line
    robots_line=$(grep -Ei '<meta[^>]*name=["'"'"']?robots["'"'"']?' "$tmp_body" | head -1 || true)
    meta_robots_value=$(_extract_attr "content" "$robots_line")
  fi

  # --- Open Graph ---
  if grep -Eqi '<meta[^>]*property=["'"'"']?og:title["'"'"']?' "$tmp_body"; then
    og_title_present="true"
  fi
  if grep -Eqi '<meta[^>]*property=["'"'"']?og:description["'"'"']?' "$tmp_body"; then
    og_description_present="true"
  fi
  if grep -Eqi '<meta[^>]*property=["'"'"']?og:image["'"'"']?' "$tmp_body"; then
    og_image_present="true"
  fi

  # --- Structured data (JSON-LD) ---
  if grep -Eqi '<script[^>]*type=["'"'"']?application/ld\+json["'"'"']?' "$tmp_body"; then
    structured_data_present="true"
  fi

  # --- Images missing alt ---
  local total_img
  total_img=$(grep -io '<img[[:space:]>]' "$tmp_body" | wc -l | tr -d ' ' || true)
  local img_with_alt
  img_with_alt=$(grep -io '<img[[:space:]>][^>]*alt=' "$tmp_body" | wc -l | tr -d ' ' || true)
  images_missing_alt_count=$(( total_img > img_with_alt ? total_img - img_with_alt : 0 ))

  jq -n \
    --argjson title_present "$title_present" \
    --arg title_value "$title_value" \
    --argjson title_length "$title_length" \
    --argjson meta_description_present "$meta_description_present" \
    --argjson meta_description_length "$meta_description_length" \
    --argjson h1_count "$h1_count" \
    --argjson lang_present "$lang_present" \
    --arg lang_value "$lang_value" \
    --argjson viewport_present "$viewport_present" \
    --argjson canonical_present "$canonical_present" \
    --arg canonical_value "$canonical_value" \
    --argjson charset_present "$charset_present" \
    --argjson meta_robots_present "$meta_robots_present" \
    --arg meta_robots_value "$meta_robots_value" \
    --argjson og_title_present "$og_title_present" \
    --argjson og_description_present "$og_description_present" \
    --argjson og_image_present "$og_image_present" \
    --argjson structured_data_present "$structured_data_present" \
    --argjson images_missing_alt_count "$images_missing_alt_count" \
    '{
      title_present: $title_present,
      title_value: $title_value,
      title_length: $title_length,
      meta_description_present: $meta_description_present,
      meta_description_length: $meta_description_length,
      h1_count: $h1_count,
      lang_present: $lang_present,
      lang_value: $lang_value,
      viewport_present: $viewport_present,
      canonical_present: $canonical_present,
      canonical_value: $canonical_value,
      charset_present: $charset_present,
      meta_robots_present: $meta_robots_present,
      meta_robots_value: $meta_robots_value,
      og_title_present: $og_title_present,
      og_description_present: $og_description_present,
      og_image_present: $og_image_present,
      structured_data_present: $structured_data_present,
      images_missing_alt_count: $images_missing_alt_count
    }' > "$html_outfile"
}
