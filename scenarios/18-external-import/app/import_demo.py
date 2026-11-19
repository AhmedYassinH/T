"""Fictional source API, archive API, and importer used only in this lab."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import signal
import sys
import time
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen

SOURCE = "http://demo-source:8080"
ARCHIVE = "http://reading-archive:8080"
INITIAL = {"id": "reading-original", "pressure": 210.5}
rows = {}


class API(BaseHTTPRequestHandler):
    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/healthz":
            self.reply(200, {"ready": True})
        elif url.path == "/openapi.json" and role == "source":
            self.reply(200, {"openapi": "3.0.3", "info": {"title": "Demo source", "version": "1"},
                             "paths": {"/readings": {"get": {"parameters": [
                                 {"name": "well", "in": "query", "schema": {"type": "string"}}],
                                 "responses": {"200": {"description": "Matching readings"}}}}}})
        elif url.path == "/readings":
            found = role == "archive" or parse_qs(url.query).get("well") == ["well-17"]
            self.reply(200, list(rows.values()) if found else [])
        else:
            self.reply(404, {"error": "path not found"})

    def do_POST(self):
        if self.path != "/readings":
            self.reply(404, {"error": "path not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size < 2048:
                raise ValueError("Invalid sample size")
            record = json.loads(self.rfile.read(size))
            if not isinstance(record["id"], str) or not isinstance(record["pressure"], (int, float)):
                raise ValueError("Invalid reading")
        except (ValueError, KeyError, TypeError):
            self.reply(400, {"error": "invalid reading"})
            return
        old = record["id"] in rows
        rows.setdefault(record["id"], record)
        self.reply(200 if old else 201, {"created": not old})


def fetch(url, item=None):
    body = json.dumps(item).encode() if item is not None else None
    req = Request(url, data=body, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=3) as response:
        return json.load(response)


def run_import():
    query = urlencode({"well": os.environ["SOURCE_WELL"]})
    incoming = fetch(SOURCE + "/readings?" + query)
    added = sum(fetch(ARCHIVE + "/readings", item)["created"] for item in incoming)
    print(f"Found {len(incoming)} source rows. Added {added} new rows.", flush=True)
    return len(incoming)


def main(action, *args):
    global role
    if action in ("source", "archive"):
        role = action
        if role == "source":
            rows[INITIAL["id"]] = INITIAL
        HTTPServer(("0.0.0.0", 8080), API).serve_forever()
    elif action == "loop":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True:
            try:
                run_import()
            except OSError as error:
                print(f"Import failed: {error}", flush=True)
            time.sleep(8)
    elif action == "probe":
        print("Source health:", fetch(SOURCE + "/healthz"))
        if run_import() == 0:
            sys.exit(2)
    elif action == "seed":
        fetch(SOURCE + "/readings", {"id": args[0], "pressure": 211.1})
    elif action == "baseline":
        if INITIAL not in fetch(ARCHIVE + "/readings"):
            sys.exit("Original reading missing")
    elif action == "validate":
        readout = [INITIAL, {"id": args[0], "pressure": 211.1}]
        for _ in range(2):
            run_import()
            if sorted(fetch(ARCHIVE + "/readings"), key=lambda x: x["id"]) != sorted(readout, key=lambda x: x["id"]):
                sys.exit("FAIL: Expected the original reading and one copy of the new reading.")
        print("PASS: Both readings are in the archive exactly once.")
    else:
        sys.exit("Unknown action")


if __name__ == "__main__":
    main(*sys.argv[1:])
