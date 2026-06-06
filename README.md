# Orbit Audits

A Bash toolkit for running batch web audits against a list of URLs.
Outputs JSON and Markdown reports per domain, covering performance,
accessibility, HTML structure, CSP, and security headers.

## Audits

<!-- markdownlint-disable MD013 MD060 -->
| Type             | Tool                              | Output file |
| ---------------- | --------------------------------- | ----------- |
| General          | Google PageSpeed API / Lighthouse | `audit_general_mobile.json`, `audit_general_desktop.json` |
| HTML Structure   | Built-in (grep/sed/jq)            | `audit_html.json` |
| Accessibility    | pa11y (WCAG2AAA)                  | `audit_accessibility.json` |
| CSP              | csp-validator                     | `audit_csp.json` |
| Security headers | Built-in (curl)                   | `audit_security_headers.json` |
<!-- markdownlint-enable MD013 MD060 -->

## Dependencies

Install via your package manager (`brew`, `apt`, etc.):

```bash
# System
curl
jq

# Node.js (npm)
npm install -g pa11y
npm install -g csp-validator
npm install -g lighthouse   # optional — PageSpeed fallback
```

Lighthouse requires Chrome or Chromium.

## Usage

Create a plain text file with one URL per line. Lines starting with `#`
are ignored:

```text
https://example.com
https://another-site.org
# this line is skipped
```

The general audit uses the
[Google PageSpeed Insights API](https://developers.google.com/speed/docs/insights/v5/get-started).
You must set an API key:

```bash
export GOOGLE_PAGESPEED_API_KEY=your_key_here
```

If the WAF blocks PageSpeed, the audit automatically falls back to
Lighthouse.

### Running audits

```bash
# Run all audits
./bulk_audits.sh urls_list.txt

# Run a specific audit type
./bulk_audits.sh urls_list.txt general
./bulk_audits.sh urls_list.txt html
./bulk_audits.sh urls_list.txt accessibility
./bulk_audits.sh urls_list.txt csp
./bulk_audits.sh urls_list.txt security

# Force Lighthouse instead of PageSpeed for the general audit
./bulk_audits.sh --lighthouse urls_list.txt

# Control report verbosity (default: focused)
./bulk_audits.sh --report focused urls_list.txt
./bulk_audits.sh --report complete urls_list.txt
```

## Output

Results are written to `audits_results/<domain>/`, one directory per URL:

```text
audits_results/
  example_com/
    audit_general_mobile.json
    audit_general_desktop.json
    audit_html.json
    audit_accessibility.json
    audit_csp.json
    audit_security_headers.json
    summary.json       # Aggregated scores across all audit types
    report.md          # Markdown report (focused or complete mode)
```

## Tests

Run the full test suite:

```bash
./tests/run_all.sh
```

For integration tests, start the test HTTP server first:

```bash
python3 tests/test_server.py &
./tests/run_all.sh
```

**Unit tests:** `test_audit_html.sh` (23), `test_audit_report.sh` (28),
`test_cli_flags.sh` (11).

**Integration tests:** `test_integration.sh` (204) — covers format flags,
gate edge cases, and regression against existing result directories.
