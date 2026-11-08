"""Fictional dependency API for the disposable DNS support exercise."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self.respond(200, {"status": "healthy"})
        else:
            self.respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/sample-job":
            self.respond(404, {"error": "not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 1024:
                raise ValueError("invalid body size")
            payload = json.loads(self.rfile.read(size))
            nonce = payload["nonce"]
            if not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-f]{32}", nonce):
                raise ValueError("invalid nonce")
        except (ValueError, KeyError, TypeError):
            self.respond(400, {"error": "invalid sample job"})
            return
        self.respond(200, {"service": "catalog-api", "status": "completed",
                           "nonce": nonce, "result": 84,
                           "backend": os.environ["POD_NAME"]})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
