"""Fictional worker: one sample application job every eight seconds."""

import argparse
import http.client
import ipaddress
import json
import os
import re
import socket
import sys
import time
import uuid


def job(nonce):
    host = os.environ.get("DEPENDENCY_HOST", "")
    report = {"host": host, "nonce": nonce}
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        return {**report, "error": "CONFIG_ERROR", "detail": "Use a Service DNS name, not an IP"}, 1
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9.])?", host):
        return {**report, "error": "CONFIG_ERROR", "detail": "Expected a hostname only"}, 1
    try:
        addresses = socket.getaddrinfo(host, 8080, type=socket.SOCK_STREAM)
        report["resolved_ips"] = sorted({item[4][0] for item in addresses})
    except socket.gaierror as error:
        return {**report, "error": "DNS_ERROR", "detail": str(error)}, 1
    connection = http.client.HTTPConnection(host, 8080, timeout=4)
    try:
        connection.request("POST", "/api/sample-job", body=json.dumps({"nonce": nonce}),
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        body = response.read(8192)
        if response.status != 200:
            return {**report, "error": "HTTP_ERROR", "status": response.status}, 1
        result = json.loads(body)
        if (result.get("nonce") != nonce or result.get("service") != "catalog-api"
                or result.get("status") != "completed" or result.get("result") != 84):
            return {**report, "error": "RESPONSE_ERROR", "detail": "Unexpected job response"}, 1
        return {**report, "status": "completed", "response": result}, 0
    except (OSError, http.client.HTTPException) as error:
        return {**report, "error": "CONNECTION_ERROR", "detail": str(error)}, 1
    except (ValueError, AttributeError) as error:
        return {**report, "error": "RESPONSE_ERROR", "detail": str(error)}, 1
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--nonce", default=None)
    args = parser.parse_args()
    if args.nonce and not re.fullmatch(r"[0-9a-f]{32}", args.nonce):
        parser.error("--nonce must contain 32 lowercase hexadecimal characters")
    while True:
        result, code = job(args.nonce or uuid.uuid4().hex)
        print(json.dumps(result), flush=True)
        if args.once:
            return code
        time.sleep(8)


if __name__ == "__main__":
    sys.exit(main())
