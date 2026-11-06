"""Small, stateless training API. Not KAPPA software or a production server."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


APP_NAME = "energy-automation-demo"
BACKEND_ID = os.environ.get("POD_NAME", "unknown")
MEASUREMENTS = [
    {"id": "sample-001", "pressure_bar": 210.5},
    {"id": "sample-002", "pressure_bar": 211.0},
    {"id": "sample-003", "pressure_bar": 210.8},
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            payload, code = {"status": "ready"}, 200
        elif path in ("/", "/api/status", "/api/measurements"):
            payload = {
                "app": APP_NAME,
                "status": "ok",
                "backend_id": BACKEND_ID,
                "nonce": self.headers.get("X-Lab-Nonce", ""),
            }
            if path == "/api/measurements":
                payload["measurements"] = MEASUREMENTS
            code = 200
        else:
            payload, code = {"error": "not found"}, 404
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Lab-Backend", BACKEND_ID)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        if urlsplit(self.path).path != "/healthz":
            print(f"backend={BACKEND_ID} client={self.client_address[0]} {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"Training API {BACKEND_ID} listening on 0.0.0.0:8080", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
