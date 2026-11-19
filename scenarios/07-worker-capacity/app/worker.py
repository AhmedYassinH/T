"""Small deterministic batch worker used by the practice exercise."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

scratch = bytearray(48 * 1024 * 1024)
for offset in range(0, len(scratch), 4096):
    scratch[offset] = 1


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/healthz", "/api/batch"):
            self.send_error(404)
            return
        job = {"processed": 8, "total": sum(range(1, 9))}
        body = json.dumps(job).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
