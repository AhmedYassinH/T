"""A small demonstration dashboard API for scenario 06."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path

config = json.loads(Path("/config/release.json").read_text())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/livez", "/readyz", "/api/status"):
            self.send_error(404)
            return
        body = json.dumps({"status": "ok", "release": config["release"],
                           "pod": os.environ["HOSTNAME"]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
