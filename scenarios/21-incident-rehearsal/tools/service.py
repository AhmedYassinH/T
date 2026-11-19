import json
import os
import re
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROLE = os.environ["ROLE"]
JOB_PATH = re.compile(r"/api/jobs/([0-9a-f]{12})(?:/(submit|complete|run))?")
JOBS = {}
READING = {"sensor": "well-17", "pressure": 210.5}


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def forward(self, host, path, method="GET"):
        try:
            with urlopen(Request(f"http://{host}{path}", method=method), timeout=3) as response:
                body = json.load(response)
                self.send_json(response.status, body)
        except HTTPError as error:
            self.send_json(error.code, json.load(error))
        except (URLError, TimeoutError) as error:
            reason = error.reason if isinstance(error, URLError) else error
            problem = "DNS lookup failed" if isinstance(reason, socket.gaierror) else "backend unavailable"
            self.log_error("%s for %s: %s", problem, host, reason)
            self.send_json(503, {"error": problem, "backend": host})

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"status": "ready"})
        elif self.path == "/api/readings" and ROLE == "portal":
            self.forward("telemetry-api", self.path)
        elif self.path == "/api/readings" and ROLE == "api":
            self.send_json(200, READING)
        elif ROLE == "api" and (match := JOB_PATH.fullmatch(self.path)) and not match[2]:
            self.send_job(match[1])
        else:
            self.send_json(404, {"error": "route not found"})

    def do_POST(self):
        match = JOB_PATH.fullmatch(self.path)
        job, action = match.groups() if match else (None, None)
        if ROLE == "worker" and action == "run":
            self.forward(os.environ["JOB_HOST"], f"/api/jobs/{job}/complete", method="POST")
        elif ROLE == "api" and action == "submit":
            JOBS.setdefault(job, "pending")
            self.send_job(job)
        elif ROLE == "api" and action == "complete" and job in JOBS:
            JOBS[job] = "completed"
            self.send_job(job)
        else:
            self.send_json(404, {"error": "unknown job or route"})

    def send_job(self, job):
        if job in JOBS:
            self.send_json(200, {"job": job, "state": JOBS[job]})
        else:
            self.send_json(404, {"error": "unknown job"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
