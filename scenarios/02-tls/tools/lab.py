"""Disposable TLS exercises. Execute only inside a Linux Kubernetes playground."""

import argparse
import base64
import contextlib
import hashlib
import http.client
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import ssl
import subprocess
import sys
import time
import uuid

from make_certs import generate


LAB = Path(__file__).resolve().parents[1]
STATE = LAB / ".state"
PKI = STATE / "pki"
NS = "kappa-practice-02"
OWNER = "tls-practice-02"
FAULTS = {
    "expired": "HTTPS stopped being trusted although the workloads look healthy.",
    "hostname": "A certificate replacement caused hostname verification failures.",
    "chain": "A clean client cannot validate the certificate presented by the portal.",
    "trust": "The portal works for another client, but this client rejects its issuer.",
    "key-mismatch": "The HTTPS gateway will not start following certificate maintenance.",
    "stale": "Renewal is recorded in Kubernetes, but clients still receive the previous certificate.",
    "upstream": "The portal TLS connection works, but API requests return gateway errors.",
}


class LabError(Exception):
    pass


def run(args, *, data=None, timeout=25, check=True):
    try:
        result = subprocess.run(list(map(str, args)), input=data, capture_output=True,
                                text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LabError(f"Command could not complete: {args[0]}: {error}") from error
    if check and result.returncode:
        # Input JSON can contain private keys. Never echo it or an entire exception object.
        raise LabError(f"{args[0]} failed: {result.stderr.strip()}")
    return result


def pem_blocks(pem):
    return re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)


def fingerprint(pem):
    blocks = pem_blocks(pem)
    if not blocks:
        raise LabError("No PEM certificate found")
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(blocks[0])).hexdigest()


def require(condition, message):
    if not condition:
        raise LabError(message)


class Lab:
    def __init__(self):
        self.session = {}
        require(not STATE.is_symlink(), "Refusing a symlinked .state directory")
        if (STATE / "session.json").exists():
            self.session = json.loads((STATE / "session.json").read_text())
        self.context = ""

    def connect(self):
        require(sys.version_info >= (3, 9), "Use Python 3.9 or newer in the playground")
        for tool in ("kubectl", "openssl", "curl"):
            require(shutil.which(tool), f"Missing {tool}; install it inside the disposable Linux playground.")
        require(sys.platform.startswith("linux"), "Run this lab in the Linux Killercoda playground, not the authoring machine.")
        curl_version = run(["curl", "--version"]).stdout
        version = re.search(r"^curl (\d+)\.(\d+)\.(\d+)", curl_version)
        require(version and tuple(map(int, version.groups())) >= (7, 76, 0),
                "Use curl 7.76 or newer for --fail-with-body")
        openssl_help = run(["openssl", "req", "-help"], check=False)
        require("-addext" in openssl_help.stdout + openssl_help.stderr,
                "OpenSSL req must support -addext (OpenSSL 1.1.1+)")
        current = run(["kubectl", "config", "current-context"]).stdout.strip()
        require(current, "No Kubernetes context is selected")
        require(not self.session or self.session.get("context") == current,
                "The current context differs from the saved lab context. Select the original context or use a fresh playground/copy.")
        self.context = current

    def k(self, *args, namespaced=True, data=None, timeout=25, check=True):
        command = ["kubectl", f"--context={self.context}", "--request-timeout=20s"]
        if namespaced:
            command += [f"--namespace={NS}"]
        return run(command + list(args), data=data, timeout=timeout, check=check)

    def obj(self, kind, name):
        return json.loads(self.k("get", kind, name, "-o", "json").stdout)

    def namespace(self):
        output = self.k("get", "namespace", NS, "--ignore-not-found", "-o", "json", namespaced=False).stdout
        return json.loads(output) if output.strip() else None

    def owned(self):
        namespace = self.namespace()
        require(namespace, "Lab namespace is absent; run setup.sh")
        require(namespace["metadata"].get("labels", {}).get("training.example.com/scenario") == OWNER,
                "Namespace is not labelled as this lab; refusing to modify it")
        require(self.session.get("uid") == namespace["metadata"]["uid"],
                "Saved namespace identity is missing or changed; use a fresh playground/copy")

    def save(self):
        (STATE / "session.json").write_text(json.dumps(self.session, indent=2) + "\n")

    def apply(self, resource):
        self.k("apply", "--server-side", "--force-conflicts", "--field-manager=tls-practice", "-f", "-",
               data=json.dumps(resource))

    def config(self, name, entries):
        self.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name}, "data": entries})

    def secret(self, name, certificate, key):
        self.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name},
                    "type": "kubernetes.io/tls", "data": {
                        "tls.crt": base64.b64encode(Path(certificate).read_bytes()).decode(),
                        "tls.key": base64.b64encode(Path(key).read_bytes()).decode()}})

    def secret_data(self):
        secret = self.obj("secret", "portal-tls")
        require(secret.get("type") == "kubernetes.io/tls", "portal-tls must remain a TLS Secret")
        return {key: base64.b64decode(value).decode() for key, value in secret.get("data", {}).items()}

    def ip(self, service):
        spec = self.obj("service", service)["spec"]
        address = spec.get("clusterIP", "")
        require(address and address != "None" and ipaddress.ip_address(address).version == 4,
                "This lab requires the standard IPv4 Service network")
        return address

    def restart(self, deployment, wait=True):
        self.k("rollout", "restart", f"deployment/{deployment}")
        if wait:
            self.k("rollout", "status", f"deployment/{deployment}", "--timeout=240s",
                   "--request-timeout=0", timeout=255)

    def wait_for(self, description, action, seconds=120):
        deadline = time.monotonic() + seconds
        last_error = "condition not met"
        while time.monotonic() < deadline:
            try:
                if action():
                    return
            except (LabError, OSError, ssl.SSLError) as error:
                last_error = str(error)
            time.sleep(3)
        raise LabError(f"Timed out waiting for {description}: {last_error}")

    def mounted_certificate_matches(self):
        mounted = self.k("exec", "deployment/tls-gateway", "--", "cat", "/etc/lab-tls/tls.crt").stdout
        return fingerprint(mounted) == fingerprint(self.secret_data()["tls.crt"])

    def reload_gateway(self):
        self.wait_for("Secret projection to reach the gateway", self.mounted_certificate_matches, seconds=180)
        self.k("exec", "deployment/tls-gateway", "--", "nginx", "-t")
        self.k("exec", "deployment/tls-gateway", "--", "nginx", "-s", "reload")

    def tls_socket(self, upstream=False):
        hostname = "api.lab.test" if upstream else "portal.lab.test"
        address = self.ip("tls-api" if upstream else "tls-gateway")
        ca = PKI / "root.crt" if upstream else STATE / "client-ca.crt"
        context = ssl.create_default_context(cafile=str(ca))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        raw = socket.create_connection((address, 443), timeout=5)
        try:
            return context.wrap_socket(raw, server_hostname=hostname)
        except Exception:
            raw.close()
            raise

    def served_fingerprint(self):
        with self.tls_socket() as connection:
            return hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()

    def https(self, path="/api/status", upstream=False):
        hostname = "api.lab.test" if upstream else "portal.lab.test"
        nonce = uuid.uuid4().hex
        connection = http.client.HTTPSConnection(hostname, 443, timeout=5)
        connection.sock = self.tls_socket(upstream=upstream)
        try:
            certificate = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
            connection.request("GET", path, headers={"Host": hostname, "X-Lab-Nonce": nonce})
            response = connection.getresponse()
            body = response.read(65536).decode()
            return {"code": response.status, "headers": dict(response.getheaders()),
                    "body": body, "nonce": nonce, "fingerprint": certificate}
        finally:
            connection.close()

    def app_response(self, path="/api/status", upstream=False):
        result = self.https(path, upstream)
        require(result["code"] == 200, f"TLS verified but HTTP status is {result['code']}: {result['body'][:160]}")
        body = json.loads(result["body"])
        pods = json.loads(self.k("get", "pods", "-l", "app=tls-api", "-o", "json").stdout)
        names = {p["metadata"]["name"] for p in pods["items"] if not p["metadata"].get("deletionTimestamp")}
        headers = {k.lower(): v for k, v in result["headers"].items()}
        require(body.get("app") == "tls-training-api" and body.get("status") == "ok", "Application identity/status is incorrect")
        require(body.get("nonce") == result["nonce"], "Response is not fresh for this request")
        require(body.get("backend_id") in names and headers.get("x-lab-backend") == body.get("backend_id"),
                "Response does not identify an expected API pod")
        require(upstream or headers.get("x-lab-gateway") == "tls-gateway", "Gateway marker is missing")
        if path == "/api/measurements":
            require(body.get("measurements") == [210.5, 211.0, 210.8], "Sample measurements are incorrect")
        return result

    def structure(self):
        for name in ("tls-api", "tls-gateway"):
            deployment = self.obj("deployment", name)
            status = deployment.get("status", {})
            require(deployment["spec"].get("replicas") == 1 and all(
                status.get(field, 0) == 1 for field in ("replicas", "updatedReplicas", "readyReplicas", "availableReplicas")),
                f"{name} must have one updated, available replica")
            require(status.get("observedGeneration", 0) >= deployment["metadata"]["generation"], "Deployment has not converged")
            for container in deployment["spec"]["template"]["spec"]["containers"]:
                require(container.get("readinessProbe") and container.get("livenessProbe"), "Keep the supplied probes")
            service = self.obj("service", name)["spec"]
            require(service.get("type") == "ClusterIP" and len(service.get("ports", [])) == 1
                    and service["ports"][0]["port"] == 443 and service["ports"][0].get("targetPort") in ("https", 8443),
                    "Keep each Service's HTTPS interface and target")
        require(self.obj("configmap", "tls-api-code")["data"]["app.py"] == (LAB / "app/app.py").read_text(),
                "Keep the supplied API code")

    def secret_pair(self):
        data = self.secret_data()
        cert_key = run(["openssl", "x509", "-pubkey", "-noout"], data=data["tls.crt"]).stdout
        private_key = run(["openssl", "pkey", "-pubout"], data=data["tls.key"]).stdout
        require(cert_key.strip() == private_key.strip(), "TLS Secret certificate and key do not match")

    def trust(self):
        require((STATE / "client-ca.crt").read_text().strip() == (PKI / "root.crt").read_text().strip(),
                "Restore the approved root CA in the client trust file")

    def active_certificate(self):
        data = self.secret_data()
        require(self.served_fingerprint() == fingerprint(data["tls.crt"]),
                "The served certificate differs from the active TLS Secret")
        if self.session.get("fault") == "stale":
            require(fingerprint(data["tls.crt"]) == fingerprint((PKI / "renewed.crt").read_text()),
                    "Keep the renewed certificate; do not roll the Secret back")

    def secure_proxy(self):
        config = self.k("exec", "deployment/tls-gateway", "--", "nginx", "-T").stdout
        config = re.sub(r"#.*", "", config)
        for name, expected in (("proxy_ssl_verify", ["on"]), ("proxy_ssl_server_name", ["on"]),
                               ("proxy_ssl_name", ["api.lab.test"]), ("proxy_pass", ["https://tls-api:443"]),
                               ("ssl_protocols", ["TLSv1.2 TLSv1.3"])):
            require(re.findall(r"\b" + name + r"\s+([^;]+);", config) == expected,
                    f"Keep the intended secure setting for {name}")
        self.k("exec", "deployment/tls-gateway", "--", "nginx", "-t")

    def validate(self):
        checks = [
            ("Workloads, probes, HTTPS interfaces, and API source retained", self.structure),
            ("TLS Secret certificate and private key match", self.secret_pair),
            ("Client trusts the approved root CA", self.trust),
            ("Live portal certificate verifies and matches the active Secret", self.active_certificate),
            ("Direct upstream HTTPS verifies and returns live API data", lambda: self.app_response(upstream=True)),
            ("Portal HTTPS returns live status data", self.app_response),
            ("Portal HTTPS returns the sample measurements", lambda: self.app_response("/api/measurements")),
            ("NGINX retains upstream verification, SNI, and intended TLS settings", self.secure_proxy),
        ]
        failures = 0
        for description, action in checks:
            try:
                action()
                print(f"PASS: {description}")
            except (LabError, OSError, ssl.SSLError, ValueError, http.client.HTTPException, KeyError) as error:
                failures += 1
                print(f"FAIL: {description}\n  {error}")
        print(f"Results: {len(checks) - failures}/{len(checks)} passed; {failures} failed.")
        return 1 if failures else 0

    def validation_log(self, filename):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = self.validate()
        (STATE / filename).write_text(output.getvalue())
        return result

    def healthy(self):
        self.session["fault"] = "healthy"
        self.session["prepared"] = False
        self.save()
        shutil.copyfile(PKI / "root.crt", STATE / "client-ca.crt")
        self.config("lab-root-ca", {"ca.crt": (PKI / "root.crt").read_text()})
        self.config("tls-api-code", {"app.py": (LAB / "app/app.py").read_text()})
        self.config("tls-gateway-config", {"nginx.conf": (LAB / "manifests/gateway.conf").read_text()})
        self.secret("portal-tls", PKI / "current.fullchain.crt", PKI / "current.key")
        self.secret("api-tls", PKI / "api.crt", PKI / "api.key")
        self.k("apply", "-f", LAB / "manifests/workloads.yaml")
        for name in ("tls-api", "tls-gateway"):
            self.restart(name)
        self.wait_for("healthy baseline validation", lambda: self.validation_log("baseline.log") == 0, seconds=90)

    def inject(self, fault):
        self.session["fault"] = fault
        self.save()
        if fault in ("expired", "hostname", "chain", "key-mismatch"):
            stem = {"expired": "expired", "hostname": "wrong-name"}.get(fault, "current")
            certificate = PKI / (f"{stem}.crt" if fault == "chain" else f"{stem}.fullchain.crt")
            key = PKI / ("unrelated.key" if fault == "key-mismatch" else f"{stem}.key")
            self.secret("portal-tls", certificate, key)
            if fault == "key-mismatch":
                self.restart("tls-gateway", wait=False)
            else:
                self.reload_gateway()
        elif fault == "trust":
            shutil.copyfile(PKI / "alternate-root.crt", STATE / "client-ca.crt")
        elif fault == "stale":
            self.secret("portal-tls", PKI / "renewed.fullchain.crt", PKI / "renewed.key")
            self.wait_for("renewed Secret projection", self.mounted_certificate_matches, seconds=180)
        elif fault == "upstream":
            config = (LAB / "manifests/gateway.conf").read_text().replace(
                "proxy_ssl_name api.lab.test;", "proxy_ssl_name old-api.lab.test;")
            self.config("tls-gateway-config", {"nginx.conf": config})
            self.restart("tls-gateway")
        self.wait_for("the intended incident", lambda: self.confirm_fault(fault), seconds=90)
        require(self.validation_log("broken.log") == 1, "Expected recovery validation to fail before the learner's repair")
        self.session["prepared"] = True
        self.save()

    def confirm_fault(self, fault):
        if fault in ("expired", "hostname", "chain", "trust"):
            try:
                self.served_fingerprint()
            except ssl.SSLCertVerificationError as error:
                expected = {"expired": (10,), "hostname": (62, 64), "chain": (20, 21), "trust": (20, 21)}
                return error.verify_code in expected[fault]
            return False
        if fault == "stale":
            return (self.app_response()["fingerprint"] == fingerprint((PKI / "current.crt").read_text())
                    and fingerprint(self.secret_data()["tls.crt"]) == fingerprint((PKI / "renewed.crt").read_text()))
        if fault == "upstream":
            return self.https()["code"] == 502
        deployment = self.obj("deployment", "tls-gateway")
        if deployment.get("status", {}).get("availableReplicas", 0) != 0:
            return False
        logs = self.k("logs", "deployment/tls-gateway", "--tail=30", check=False).stdout.lower()
        return "key values mismatch" in logs or "key_values_mismatch" in logs

    def setup(self, fault, reset=False):
        if self.namespace() or STATE.exists():
            require(reset, "Lab or saved state already exists. Resume it, use fault.sh to switch, or setup.sh --reset to discard it.")
            self.cleanup()
        nodes = json.loads(self.k("get", "nodes", "-o", "json", namespaced=False).stdout)
        require(any(c.get("type") == "Ready" and c.get("status") == "True"
                    for node in nodes["items"] for c in node.get("status", {}).get("conditions", [])), "No Ready node found")
        STATE.mkdir(mode=0o700)
        self.session = {"context": self.context, "fault": "healthy"}
        self.save()
        namespace = {"apiVersion": "v1", "kind": "Namespace", "metadata": {
            "name": NS, "labels": {"training.example.com/scenario": OWNER}}}
        self.k("create", "-f", "-", namespaced=False, data=json.dumps(namespace))
        self.session["uid"] = self.namespace()["metadata"]["uid"]
        self.save()
        print(f"Preparing TLS fixtures in {NS}. No system trust store or hosts file is modified.", flush=True)
        generate(PKI)
        self.healthy()
        self.inject(fault)
        self.task()

    def switch(self, fault):
        self.owned()
        print("Restoring the lab baseline before the next fault; this discards the current attempt.", flush=True)
        self.healthy()
        self.inject(fault)
        self.task()

    def task(self):
        require(self.session.get("prepared"), "The incident has not finished preparation. Complete setup or select a fault successfully first.")
        fault = self.session.get("fault", "healthy")
        print(f"\nScenario ready. Selected exercise: {fault}\n")
        print(FAULTS.get(fault, "The baseline is healthy."))
        print(f"Namespace: {NS}; portal: https://portal.lab.test/api/status")
        print("\nSYSTEM: operations staff read sample measurements through a fictional HTTPS portal.")
        print("NGINX is the portal entry point; a small HTTPS API supplies status and measurement data.")
        print("No separate browser UI, database, public DNS record, or external CA service is deployed.")
        print("Intended path: playground client -> tls-gateway Service:443 -> NGINX Pod:8443")
        print("              -> tls-api Service:443 -> API Pod:8443. Both Deployments have one replica.")
        print("There are TWO TLS connections: client verifies portal.lab.test; gateway verifies api.lab.test.")
        print("Normal result: GET /api/status returns HTTP 200, app=tls-training-api, status=ok;")
        print("GET /api/measurements returns three sample readings through the same verified gateway path.")
        print("backend_id names the responding API Pod; nonce echoes the fresh request ID.\n")
        print("CONFIGURATION: portal-tls is the gateway's certificate-chain/private-key Secret;")
        print("api-tls is the API's certificate/key Secret. lab-root-ca holds the public CA for upstream trust.")
        print("NGINX loads its mounted configuration and TLS files at start/reload; ConfigMap subPath changes need a new Pod.")
        print(".state/pki contains disposable training fixtures, not automatically active server files.")
        print("HELPER: request.sh runs curl on the playground node, mapping the portal name to its Service IP")
        print("with --resolve while retaining hostname verification and using .state/client-ca.crt for trust.")
        print("It reproduces the frontend client path; --upstream separately tests the API connection.")
        print("A verified frontend response alone does not establish that upstream TLS is healthy.")
        print("Workload health probes check local HTTP/TCP responses, not certificate validity.\n")
        print("Preserve HTTPS, hostname verification, the approved CA, and upstream certificate verification.")
        print("For renewal, keep the renewed certificate; do not revert it. Diagnose before changing resources.")
        print("Reproduce: bash request.sh\nInspect: bash inspect.sh\nValidate: bash validate.sh")
        print("Hints: bash hint.sh 1 (then 2 or 3). Reference repair: bash solution.sh")
        print("Recovery validation is expected to fail before repair, including the stale-certificate case.")
        address = self.ip("tls-gateway")
        print("\nEquivalent manual request (from the playground node):")
        print(f"curl --noproxy '*' --resolve portal.lab.test:443:{address} --cacert .state/client-ca.crt -i https://portal.lab.test/api/status")

    def request(self, path, insecure=False, upstream=False, ca=None):
        require(path.startswith("/") and "\n" not in path, "Supply an API path beginning with /")
        host = "api.lab.test" if upstream else "portal.lab.test"
        address = self.ip("tls-api" if upstream else "tls-gateway")
        ca = Path(ca) if ca else (PKI / "root.crt" if upstream else STATE / "client-ca.crt")
        args = ["curl", "--silent", "--show-error", "--noproxy", "*", "--fail-with-body", "--connect-timeout", "3", "--max-time", "12",
                "--resolve", f"{host}:443:{address}", "--header", f"X-Lab-Nonce: {uuid.uuid4().hex}", "-i"]
        args += ["--insecure"] if insecure else ["--cacert", str(ca)]
        args += [f"https://{host}{path}"]
        result = run(args, timeout=18, check=False)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return result.returncode

    def inspect(self, upstream=False):
        host = "api.lab.test" if upstream else "portal.lab.test"
        address = self.ip("tls-api" if upstream else "tls-gateway")
        ca = PKI / "root.crt" if upstream else STATE / "client-ca.crt"
        print(f"Inspecting {address}:443 with SNI/hostname {host}; trust file: {ca}", flush=True)
        result = run(["openssl", "s_client", "-connect", f"{address}:443", "-servername", host,
                      "-showcerts", "-verify_hostname", host, "-verify_return_error", "-CAfile", ca],
                     data="", timeout=15, check=False)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return result.returncode

    def solution(self):
        fault = self.session.get("fault")
        require(fault in FAULTS, "No active fault recorded; select an exercise first")
        print(f"Applying the reference repair for {fault}.", flush=True)
        if fault == "trust":
            shutil.copyfile(PKI / "root.crt", STATE / "client-ca.crt")
        elif fault in ("expired", "hostname", "chain", "key-mismatch"):
            self.secret("portal-tls", PKI / "current.fullchain.crt", PKI / "current.key")
            if fault == "key-mismatch":
                self.restart("tls-gateway")
            else:
                self.reload_gateway()
        elif fault == "stale":
            self.reload_gateway()
        elif fault == "upstream":
            self.config("tls-gateway-config", {"nginx.conf": (LAB / "manifests/gateway.conf").read_text()})
            self.restart("tls-gateway")
        self.wait_for("recovery validation", lambda: self.validation_log("solution.log") == 0, seconds=90)
        return self.validate()

    def cleanup(self):
        if self.namespace():
            self.owned()
            self.k("delete", "namespace", NS, "--wait=true", "--timeout=120s", "--request-timeout=0",
                   namespaced=False, timeout=135)
        if STATE.exists():
            require(not STATE.is_symlink() and STATE.resolve() == LAB / ".state", "Unsafe state directory; refusing cleanup")
            shutil.rmtree(STATE)
        self.session = {}
        print("Lab namespace and its local runtime state removed. Other scenarios are unchanged.")

    def hint(self, level):
        print("Separate TCP reachability, TLS verification, HTTP response, and upstream TLS. Use curl and openssl with the intended hostname and CA.")
        if level >= 2:
            print({
                "expired": "Inspect the validity dates on the certificate actually served.",
                "hostname": "Compare the URL/SNI hostname to the served certificate's SANs.",
                "chain": "A root trust anchor does not replace an intermediate the server must send.",
                "trust": "Compare the client's CA file to the approved root in ConfigMap lab-root-ca.",
                "key-mismatch": "Inspect gateway startup logs and compare certificate/key public keys.",
                "stale": "Compare the active Secret, projected certificate, and served certificate fingerprints.",
                "upstream": "Inspect gateway logs and the HTTPS upstream's expected hostname and trust.",
            }.get(self.session.get("fault"), "Select a fault first."))
        if level >= 3:
            print("Fixture certificates are in .state/pki; the client uses .state/client-ca.crt. Active TLS Secret: portal-tls. After fixing projected files, NGINX needs a validated reload; ConfigMap subPath configuration changes need a rollout.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("setup")
    setup.add_argument("fault", choices=FAULTS, nargs="?", default="expired")
    setup.add_argument("--reset", action="store_true")
    fault = commands.add_parser("fault")
    fault.add_argument("fault", choices=FAULTS, nargs="?")
    fault.add_argument("--list", action="store_true")
    request = commands.add_parser("request")
    request.add_argument("path", nargs="?", default="/api/status")
    request.add_argument("--insecure", action="store_true", help="Diagnostic only; validation never skips verification")
    request.add_argument("--upstream", action="store_true")
    request.add_argument("--ca")
    inspect = commands.add_parser("inspect")
    inspect.add_argument("--upstream", action="store_true")
    hint = commands.add_parser("hint")
    hint.add_argument("level", type=int, choices=(1, 2, 3), nargs="?", default=1)
    for name in ("validate", "solution", "cleanup", "task"):
        commands.add_parser(name)
    args = parser.parse_args()
    if args.command == "fault" and (args.list or not args.fault):
        for name, ticket in FAULTS.items():
            print(f"{name:14s} {ticket}")
        return 0
    os.umask(0o077)
    lab = Lab()
    if args.command == "hint":
        lab.hint(args.level)
        return 0
    lab.connect()
    if args.command == "setup":
        lab.setup(args.fault, args.reset)
        return 0
    if args.command == "cleanup":
        lab.cleanup()
        return 0
    lab.owned()
    if args.command == "fault":
        lab.switch(args.fault)
    elif args.command == "request":
        return lab.request(args.path, args.insecure, args.upstream, args.ca)
    elif args.command == "inspect":
        return lab.inspect(args.upstream)
    elif args.command == "validate":
        return lab.validate()
    elif args.command == "solution":
        return lab.solution()
    elif args.command == "task":
        lab.task()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (LabError, RuntimeError, OSError, ValueError, KeyError, http.client.HTTPException) as error:
        print(f"ERROR: {error}\nA failed setup is not a prepared exercise. If setup failed, inspect pod events/logs and retry with --reset after addressing the cause.", file=sys.stderr)
        sys.exit(2)
