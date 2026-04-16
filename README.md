# Orbit Audits

Bash toolkit. Run batch web audits across URL list. Output JSON per domain (performance, a11y, CSP, security headers).

## Audits

| Type            | Tool                          | Output file                        |
|-----------------|-------------------------------|------------------------------------|
| General         | Google PageSpeed API / Lighthouse | `audit_general_mobile.json`, `audit_general_desktop.json` |
| Accessibility   | pa11y (WCAG2AAA)              | `audit_accessibility.json`         |
| CSP             | csp-validator                 | `audit_csp.json`                   |
| Security headers| Built-in (curl)               | `audit_security_headers.json`      |

## Dependencies

Install via package manager (`brew`, `apt`, etc.):

```bash
# System
curl
jq

# Node.js (npm)
npm install -g pa11y
npm install -g csp-validator
npm install -g lighthouse   # optional — PageSpeed fallback
```

Lighthouse require Chrome/Chromium.

## Usage

Create plain text file. One URL per line (`#` ignore line):

```
https://example.com
https://another-site.org
# this line is skipped
```

General audit use [Google PageSpeed Insights API](https://developers.google.com/speed/docs/insights/v5/get-started). Require key:
```bash
export GOOGLE_PAGESPEED_API_KEY=your_key_here
```
If WAF block PageSpeed, auto-fallback to Lighthouse.

Run:

```bash
# Run all audits
./bulk_audits.sh urls_list.txt

# Run specific audit
./bulk_audits.sh urls_list.txt general
./bulk_audits.sh urls_list.txt accessibility
./bulk_audits.sh urls_list.txt csp
./bulk_audits.sh urls_list.txt security

# Force Lighthouse for general
./bulk_audits.sh --lighthouse urls_list.txt
```

## Output

Results write to `audits_results/<domain>/`. One dir per URL:

```
audits_results/
  example_com/
    audit_general_mobile.json
    audit_general_desktop.json
    audit_accessibility.json
    audit_csp.json
    audit_security_headers.json
```
