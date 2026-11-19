"""Two simple HTTP components for the reporting metrics exercise."""
from collections import Counter
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from urllib.error import URLError
from urllib.request import urlopen
from uuid import uuid4

OUTCOMES = Counter()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, payload, kind="application/json"):
        body = json.dumps(payload).encode() if kind == "application/json" else payload.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ready": True})
        elif os.environ.get("ROLE") == "calculator":
            if self.path == "/api/total":
                self.reply(200, {"total": 36})
            else:
                self.reply(404, {"error": "path not found"})
        elif self.path == "/metrics":
            prefix = "# TYPE training_jobs_total counter\n"
            body = "".join(f'training_jobs_total{{outcome="{name}"}} {OUTCOMES[name]}\n'
                           for name in ("ok", "failed"))
            self.reply(200, prefix + body, "text/plain; version=0.0.4")
        elif self.path == "/api/job":
            job = uuid4().hex
            target = "http://report-calculator:8080" + os.environ["CALCULATOR_PATH"]
            try:
                with urlopen(target, timeout=2) as result:
                    total = json.load(result)["total"]
            except (URLError, ValueError, KeyError, TimeoutError) as error:
                OUTCOMES["failed"] += 1
                print(f"job {job} failed calling {target}: {error}", flush=True)
                self.reply(502, {"status": "failed", "job": job})
            else:
                OUTCOMES["ok"] += 1
                print(f"job {job} completed", flush=True)
                self.reply(200, {"status": "ok", "total": total, "job": job})
        else:
            self.reply(404, {"error": "path not found"})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
