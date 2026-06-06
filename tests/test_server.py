#!/usr/bin/env python3
"""Test HTTP server for integration tests. Serves HTML fixtures with configurable
status codes and content types via URL path segments.

Paths:
  /<status>/<fixture>          e.g. /200/valid_page.html
  /<status>/ct/<content-type>  e.g. /403/ct/text/plain
  /redirect/target             returns 302 to <target>
  /empty                       empty body, 200, text/html
  /                            serve fixtures/html/ directory
"""
import http.server
import os
import sys
import urllib.parse

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "html")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=FIXTURES, **kwargs)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.strip("/")
        parts = path.split("/") if path else [""]

        # /<status>/<path...>
        if len(parts) >= 2 and parts[0].isdigit():
            status = int(parts[0])
            self._respond_status(status, parts[1:])
            return

        # /redirect/<target>
        if len(parts) >= 2 and parts[0] == "redirect":
            target = "/" + "/".join(parts[1:])
            self.send_response(302)
            self.send_header("Location", target)
            self.end_headers()
            return

        # /empty
        if path == "empty":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            return

        # Default: serve from fixtures
        super().do_GET()

    def _respond_status(self, status, remaining):
        # remaining[0] may be "ct" for custom content-type
        if len(remaining) >= 2 and remaining[0] == "ct":
            content_type = "/".join(remaining[1:])
            body = ""
        else:
            content_type = "text/html"
            filename = "/".join(remaining)
            filepath = os.path.join(FIXTURES, filename)
            if os.path.isfile(filepath):
                with open(filepath, "rb") as f:
                    body = f.read()
            else:
                body = b"<html><body>Not found</body></html>"
                status = 404
                content_type = "text/html"

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if isinstance(body, str):
            body = body.encode()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # silent


if __name__ == "__main__":
    httpd = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"TEST_SERVER:{PORT}\n")
    sys.stderr.flush()
    httpd.serve_forever()
