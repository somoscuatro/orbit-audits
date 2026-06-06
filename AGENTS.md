# Project: Orbit Audits

See `README.md` for CLI usage, dependencies, output structure.

## Architecture

- `bulk_audits.sh` = sole entry point. `audit_*.sh` scripts sourced (not executed).
- **HTTP Fetch**: Single `curl` per URL. Temp files (`tmp_headers`, `tmp_body`) shared across audits (CSP, security, HTML). Minimize network requests.
- **HTML Gate**: `is_valid_html_page()` (`audit_html.sh`) validates status=200, Content-Type has `text/html` or `application/xhtml+xml`, and body non-empty. Non-HTML responses skip HTML-dependent audits (general, accessibility, HTML). CSP and security audits run regardless.
- **Strategy Pattern**: `bulk_audits.sh` dynamically source `audit_general_pagespeed.sh` or `audit_general_lighthouse.sh`. Fallback Lighthouse trigger auto on API/WAF errors.
- **Report**: `audit_report.sh` aggregates all audit results into `summary.json` and `report.md` (focused or complete mode via `--report` flag).
- **Tests**: `tests/run_all.sh` runs all unit and integration tests. `tests/test_server.py` provides configurable HTTP server for integration tests.
- **Scope**: `get_http_header()` (in `bulk_audits.sh`) globally available to sourced scripts.

## Code Style

- Check `.editorconfig`.
- `bulk_audits.sh`: `set -euo pipefail`.
- `audit_*.sh`: Intentional `|| true` prevent individual tool failures abort whole run.
- Prefer Bash-native string manipulation (e.g. `${var//pattern/replace}`) over `sed`/`awk`.

## Agent Behavior

- No filler. No "Now I will...", "I try...". No pleasantries, politeness, compliments, or pseudo-human behavior. Act direct.
- Think first. Read files before write. Read once unless changed.
- Target edits. No full rewrite if small fix work.
- Simple fix > over-engineer.
- Skip files > 100KB unless explicitly required.
- Recommend new session on unrelated task.
- Suggest `/cost` on long sessions to monitor cache.
- Run tests before finish.
- User instruction override all.
