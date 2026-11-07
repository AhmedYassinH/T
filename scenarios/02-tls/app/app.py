"""Small HTTPS teaching API; not a production server."""

import json
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ("/api/status", "/api/measurements", "/healthz"):
            body = {
                "app": "tls-training-api",
                "status": "ok",
                "backend_id": os.environ["POD_NAME"],
                "nonce": self.headers.get("X-Lab-Nonce", ""),
            }
            if path == "/api/measurements":
                body["measurements"] = [210.5, 211.0, 210.8]
            code = 200
        else:
            body, code = {"error": "not found"}, 404
        encoded = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Lab-Backend", os.environ["POD_NAME"])
        self.end_headers()
        self.wfile.write(encoded)


if __name__ == "__main__":
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain("/etc/api-tls/tls.crt", "/etc/api-tls/tls.key")
    server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("HTTPS training API listening on 8443", flush=True)
    server.serve_forever()
