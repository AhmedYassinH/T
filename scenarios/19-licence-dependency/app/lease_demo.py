"""Simulated licence dependency. All tokens and business results are fixtures."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4

FEATURE = "pressure-report"


class Server(BaseHTTPRequestHandler):
    def reply(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ready": True})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/lease":
            self.reply(404, {"error": "not found"})
        elif self.headers.get("X-Demo-Feature") != FEATURE:
            self.reply(403, {"error": "unknown feature"})
        elif int(Path("/policy/seats").read_text()) < 1:
            self.reply(409, {"error": "no seats available"})
        else:
            self.reply(200, {"feature": FEATURE, "lease": uuid4().hex})
            print("Granted demo lease", flush=True)


def run_report(expect):
    url = os.environ["LICENSE_ENDPOINT"]
    req = Request(url + "/lease", data=b"", headers={"X-Demo-Feature": FEATURE})
    try:
        with urlopen(req, timeout=4) as res:
            lease = json.load(res)
    except HTTPError as error:
        detail = json.load(error).get("error")
        print(f"Licence service returned HTTP {error.code}: {detail}")
        sys.exit(not (expect == "capacity" and error.code == 409 and detail == "no seats available"))
    except (URLError, TimeoutError) as error:
        print(f"Licence service could not be reached: {error}")
        sys.exit(expect != "unreachable")
    if lease.get("feature") != FEATURE or not lease.get("lease"):
        sys.exit("Licence service did not grant the required feature")
    print(f"Report completed with a demo lease {lease['lease'][:8]}. Total = 36.")
    sys.exit(expect != "healthy")


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        HTTPServer(("0.0.0.0", 8080), Server).serve_forever()
    else:
        run_report(sys.argv[2])
