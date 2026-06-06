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

  # Helper: extract attribute value from a tag line
  # Usage: _extract_attr <attr_name> <grep_output>
  _extract_attr() {
    local attr="$1"
    local line="$2"
    echo "$line" | grep -oi "${attr}=[\"']?[^\"'[:space:]>]*" | sed -E "s/${attr}=[\"']?//; s/[\"']$//" | head -1 || true
  }

  # Helper: match an HTML tag with optional attribute
  _has_tag_attr() {
    local tag="$1"
    local attr="$2"
    local val="$3"
    local q='["'"'"']?'
    grep -qi "<${tag}[^>]*${attr}=${q}${val}${q}" "$tmp_body" 2>/dev/null || true
    [[ $? -eq 0 ]]
  }

  # --- Title ---
  if grep -qi '<title' "$tmp_body"; then
    title_present="true"
    title_value=$(grep -io '<title[^>]*>[^<]*</title>' "$tmp_body" | sed -E 's/<[^>]*>//g' | head -1 || true)
    title_length=${#title_value}
  fi || true

  # --- Meta description ---
  if grep -qi '<meta[^>]*name=["'"'"']?description["'"'"']?' "$tmp_body"; then
    meta_description_present="true"
    local desc_line
    desc_line=$(grep -i '<meta[^>]*name=["'"'"']?description["'"'"']?' "$tmp_body" | head -1 || true)
    local desc_content
    desc_content=$(_extract_attr "content" "$desc_line")
    meta_description_length=${#desc_content}
  fi || true

  # --- H1 count ---
  h1_count=$(grep -cio '<h1[[:space:]>]' "$tmp_body" || echo 0)

  # --- Lang attribute ---
  if grep -qi '<html[^>]*lang=' "$tmp_body"; then
    lang_present="true"
    lang_value=$(grep -io '<html[^>]*lang=["'"'"']?[a-zA-Z-]+' "$tmp_body" | sed -E "s/.*lang=[\"']?//; s/[\"']$//" | head -1 || true)
  fi || true

  # --- Viewport ---
  if grep -qi '<meta[^>]*name=["'"'"']?viewport["'"'"']?' "$tmp_body"; then
    viewport_present="true"
  fi || true

  # --- Canonical ---
  if grep -qi '<link[^>]*rel=["'"'"']?canonical["'"'"']?' "$tmp_body"; then
    canonical_present="true"
    local canon_line
    canon_line=$(grep -i '<link[^>]*rel=["'"'"']?canonical["'"'"']?' "$tmp_body" | head -1 || true)
    canonical_value=$(_extract_attr "href" "$canon_line")
  fi || true

  # --- Charset ---
  if grep -qi '<meta[^>]*charset=' "$tmp_body"; then
    charset_present="true"
  fi || true

  # --- Meta robots ---
  if grep -qi '<meta[^>]*name=["'"'"']?robots["'"'"']?' "$tmp_body"; then
    meta_robots_present="true"
    local robots_line
    robots_line=$(grep -i '<meta[^>]*name=["'"'"']?robots["'"'"']?' "$tmp_body" | head -1 || true)
    meta_robots_value=$(_extract_attr "content" "$robots_line")
  fi || true

  # --- Open Graph ---
  if grep -qi '<meta[^>]*property=["'"'"']?og:title["'"'"']?' "$tmp_body"; then
    og_title_present="true"
  fi || true
  if grep -qi '<meta[^>]*property=["'"'"']?og:description["'"'"']?' "$tmp_body"; then
    og_description_present="true"
  fi || true
  if grep -qi '<meta[^>]*property=["'"'"']?og:image["'"'"']?' "$tmp_body"; then
    og_image_present="true"
  fi || true

  # --- Structured data (JSON-LD) ---
  if grep -qi '<script[^>]*type=["'"'"']?application/ld\+json["'"'"']?' "$tmp_body"; then
    structured_data_present="true"
  fi || true

  # --- Images missing alt ---
  local total_img
  total_img=$(grep -cio '<img[[:space:]>]' "$tmp_body" || echo 0)
  local img_with_alt
  img_with_alt=$(grep -cio '<img[[:space:]>][^>]*alt=' "$tmp_body" || echo 0)
  images_missing_alt_count=$((total_img - img_with_alt))

  # --- Escape string values for JSON ---
  _json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
  }

  title_value=$(_json_escape "$title_value")
  lang_value=$(_json_escape "$lang_value")
  canonical_value=$(_json_escape "$canonical_value")
  meta_robots_value=$(_json_escape "$meta_robots_value")

  cat >"$html_outfile" <<HTMLJSON
{
  "title_present": $title_present,
  "title_value": "$title_value",
  "title_length": $title_length,
  "meta_description_present": $meta_description_present,
  "meta_description_length": $meta_description_length,
  "h1_count": $h1_count,
  "lang_present": $lang_present,
  "lang_value": "$lang_value",
  "viewport_present": $viewport_present,
  "canonical_present": $canonical_present,
  "canonical_value": "$canonical_value",
  "charset_present": $charset_present,
  "meta_robots_present": $meta_robots_present,
  "meta_robots_value": "$meta_robots_value",
  "og_title_present": $og_title_present,
  "og_description_present": $og_description_present,
  "og_image_present": $og_image_present,
  "structured_data_present": $structured_data_present,
  "images_missing_alt_count": $images_missing_alt_count
}
HTMLJSON
}
