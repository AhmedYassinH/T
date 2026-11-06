"""Read-only HTTP diagnostic client, sent to the existing lab-client pod."""

import argparse
import json
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--mode", choices=["inspect", "status", "api", "measurements"], default="inspect")
    parser.add_argument("--expect-code", type=int, default=200)
    parser.add_argument("--via-gateway", action="store_true")
    parser.add_argument("--allowed-backends", default="")
    args = parser.parse_args()
    nonce = uuid.uuid4().hex
    request = Request(args.url, headers={"X-Lab-Nonce": nonce, "Cache-Control": "no-cache"})
    opener = build_opener(ProxyHandler({}), NoRedirect())
    try:
        try:
            response = opener.open(request, timeout=7)
        except HTTPError as error:
            response = error
        with response:
            code = response.code
            headers = dict(response.headers.items())
            gateway = response.headers.get("X-Lab-Gateway", "")
            backend_header = response.headers.get("X-Lab-Backend", "")
            raw = response.read(65536).decode("utf-8", errors="replace")
    except (URLError, TimeoutError, OSError) as error:
        print(json.dumps({"url": args.url, "error": str(error)}))
        return 1

    errors = []
    if code != args.expect_code:
        errors.append(f"expected HTTP {args.expect_code}, got {code}")
    if args.via_gateway and gateway != "portal-gateway":
        errors.append("gateway response marker missing")

    if args.mode in ("api", "measurements"):
        try:
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError("JSON body is not an object")
            if payload.get("app") != "energy-automation-demo" or payload.get("status") != "ok":
                errors.append("expected application response missing")
            if payload.get("nonce") != nonce:
                errors.append("response does not echo this request's unique nonce")
            backend = payload.get("backend_id")
            allowed = set(filter(None, args.allowed_backends.split(",")))
            if not backend or backend_header != backend or (allowed and backend not in allowed):
                errors.append("response is not from an expected API replica")
            if args.mode == "measurements":
                expected = [
                    {"id": "sample-001", "pressure_bar": 210.5},
                    {"id": "sample-002", "pressure_bar": 211.0},
                    {"id": "sample-003", "pressure_bar": 210.8},
                ]
                if payload.get("measurements") != expected:
                    errors.append("expected sample measurements are missing or changed")
        except (ValueError, TypeError) as error:
            errors.append(f"invalid application JSON: {error}")

    print(json.dumps({"url": args.url, "http_status": code, "headers": headers,
                      "body": raw, "passed": not errors, "errors": errors}, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
