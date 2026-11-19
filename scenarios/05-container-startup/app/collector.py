"""A small synthetic reading collector used by scenario 05."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os

station = os.environ["STATION_ID"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/healthz", "/api/station"):
            self.send_error(404)
            return
        payload = {"status": "ok", "station": station}
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
