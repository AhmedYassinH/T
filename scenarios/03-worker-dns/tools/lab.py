"""Scenario 03 orchestration. Run only in a disposable Linux Kubernetes playground."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid


LAB = Path(__file__).resolve().parents[1]
STATE = LAB / ".state"
NS = "kappa-practice-03"
LABEL = "training.example.com/scenario"
OWNER = "worker-dns-practice-03"
IMAGE = "python:3.12.16-alpine3.24"
GOOD_HOST = f"catalog-api.{NS}"
# One application configuration fault. The cluster DNS configuration is untouched.
WRONG_NS = "kappa-practice-30"
BAD_HOST = f"catalog-api.{WRONG_NS}"


class LabError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise LabError(message)


def run(args, *, data=None, timeout=35, check=True):
    try:
        result = subprocess.run(list(map(str, args)), input=data, text=True,
                                capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LabError(f"Command could not complete: {args[0]}: {error}") from error
    if check and result.returncode:
        raise LabError(f"{args[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result


class Lab:
    def __init__(self):
        require(not STATE.is_symlink(), "Refusing a symlinked .state directory")
        self.session = {}
        if (STATE / "session.json").exists():
            self.session = json.loads((STATE / "session.json").read_text())
        self.context = ""

    def connect(self):
        require(sys.platform.startswith("linux"), "Run this lab in Killercoda, not the authoring machine")
        require(sys.version_info >= (3, 9), "Python 3.9 or newer is required on the playground node")
        require(shutil.which("kubectl"), "kubectl is required in the Kubernetes playground")
        self.context = run(["kubectl", "config", "current-context"]).stdout.strip()
        require(self.context, "Select a Kubernetes context first")
        require(not self.session or self.session.get("context") == self.context,
                "Context differs from saved state; select the original context or use a fresh lab copy")

    def k(self, *args, namespaced=True, data=None, timeout=35, check=True):
        command = ["kubectl", f"--context={self.context}", "--request-timeout=20s"]
        if namespaced:
            command.append(f"--namespace={NS}")
        return run(command + list(args), data=data, timeout=timeout, check=check)

    def obj(self, kind, name):
        return json.loads(self.k("get", kind, name, "-o", "json").stdout)

    def namespace(self, name=NS):
        output = self.k("get", "namespace", name, "--ignore-not-found", "-o", "json",
                        namespaced=False).stdout.strip()
        return json.loads(output) if output else None

    def owned(self):
        namespace = self.namespace()
        require(namespace is not None, "Lab namespace is absent; run setup.sh")
        require(namespace["metadata"].get("labels", {}).get(LABEL) == OWNER,
                "Namespace belongs to something else; refusing to modify it")
        require(self.session.get("uid") == namespace["metadata"]["uid"],
                "Saved namespace UID is missing or changed; refusing to modify this namespace")

    def save(self):
        (STATE / "session.json").write_text(json.dumps(self.session, indent=2) + "\n")

    def apply(self, resource):
        self.k("apply", "-f", "-", data=json.dumps(resource))

    def config(self, name, entries):
        self.apply({"apiVersion": "v1", "kind": "ConfigMap",
                    "metadata": {"name": name}, "data": entries})

    def restart_worker(self):
        self.k("rollout", "restart", "deployment/job-worker")
        self.rollout("job-worker")

    def rollout(self, name):
        self.k("rollout", "status", f"deployment/{name}", "--timeout=240s",
               "--request-timeout=0", timeout=255)

    def pods(self, app):
        items = json.loads(self.k("get", "pods", "-l", f"app={app}", "-o", "json").stdout)["items"]
        return [pod for pod in items if not pod["metadata"].get("deletionTimestamp")]

    def pod(self, app):
        pods = self.pods(app)
        require(len(pods) == 1, f"Expected one current {app} Pod; finish its rollout first")
        pod = pods[0]
        require(pod.get("status", {}).get("phase") == "Running" and any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in pod.get("status", {}).get("conditions", [])), f"{app} Pod is not Ready")
        return pod

    def execute(self, *args, check=True):
        name = self.pod("job-worker")["metadata"]["name"]
        return self.k("exec", name, "-c", "worker", "--", *args, timeout=45, check=check)

    def attempt(self):
        nonce = uuid.uuid4().hex
        process = self.execute("python", "/app/worker.py", "--once", "--nonce", nonce, check=False)
        try:
            report = json.loads(process.stdout)
        except ValueError as error:
            raise LabError(f"Worker did not produce a JSON job result: {process.stderr.strip()}") from error
        require(report.get("nonce") == nonce, "Worker result did not match the fresh job nonce")
        return process, report

    def code_data(self):
        return {name: (LAB / "app" / name).read_text() for name in ("server.py", "worker.py")}

    def structure(self):
        require(self.obj("configmap", "dns-lab-code").get("data") == self.code_data(),
                "Keep the supplied API and worker source unchanged")
        for name, container_name, filename in (("catalog-api", "api", "server.py"),
                                                ("job-worker", "worker", "worker.py")):
            deployment = self.obj("deployment", name)
            spec = deployment["spec"]
            require(spec.get("replicas") == 1, f"Keep one {name} replica")
            require(spec["selector"]["matchLabels"] == {"app": name}, f"Keep the {name} selector")
            require(spec["template"]["metadata"]["labels"].get("app") == name,
                    f"Keep the {name} Pod label")
            current = self.pod(name)
            for pod_spec in (spec["template"]["spec"], current["spec"]):
                require(pod_spec.get("dnsPolicy", "ClusterFirst") == "ClusterFirst"
                        and not pod_spec.get("hostNetwork") and not pod_spec.get("hostAliases")
                        and not pod_spec.get("dnsConfig"),
                        f"Keep standard cluster DNS and no host aliases for {name}")
                containers = pod_spec["containers"]
                require(len(containers) == 1, f"Keep the original {name} container")
                container = containers[0]
                require(container["name"] == container_name and container["image"] == IMAGE
                        and container.get("command") == ["python", "-u", f"/app/{filename}"]
                        and not container.get("args") and not container.get("envFrom"),
                        f"Keep the original {name} image, command, and configuration mechanism")
                require(container.get("volumeMounts") == [{"name": "code", "mountPath": "/app", "readOnly": True}],
                        f"Keep the original {name} code mount")
                volumes = pod_spec.get("volumes", [])
                require(len(volumes) == 1 and volumes[0]["name"] == "code"
                        and volumes[0].get("configMap", {}).get("name") == "dns-lab-code",
                        f"Keep the original {name} code volume")
                env = container.get("env", [])
                if name == "job-worker":
                    host_entries = [entry for entry in env if entry["name"] == "DEPENDENCY_HOST"]
                    require(host_entries == [{"name": "DEPENDENCY_HOST", "valueFrom": {
                        "configMapKeyRef": {"name": "worker-settings", "key": "DEPENDENCY_HOST"}}}],
                        "Keep DEPENDENCY_HOST sourced from worker-settings")
                    require({e["name"] for e in env} == {"DEPENDENCY_HOST", "PYTHONDONTWRITEBYTECODE"},
                            "Keep the supplied worker environment variables")
        service = self.obj("service", "catalog-api")
        require(service["spec"].get("type", "ClusterIP") == "ClusterIP"
                and service["spec"]["selector"] == {"app": "catalog-api"},
                "Keep the catalog-api ClusterIP Service and selector")
        ports = service["spec"]["ports"]
        require(len(ports) == 1 and ports[0]["port"] == 8080 and ports[0]["targetPort"] == "http",
                "Keep catalog-api port 8080 targeting the named http port")
        require(ipaddress.ip_address(service["spec"]["clusterIP"]).version == 4,
                "This exercise targets the standard IPv4 playground")

    def check_job(self):
        process, report = self.attempt()
        require(process.returncode == 0 and report.get("status") == "completed", json.dumps(report))
        host = report["host"].rstrip(".")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise LabError("Hard-coded IPs do not count as DNS recovery")
        configured = self.obj("configmap", "worker-settings")["data"]["DEPENDENCY_HOST"]
        require(report["host"] == configured, "Running worker has stale configuration; replace its Pod")
        cluster_ip = self.obj("service", "catalog-api")["spec"]["clusterIP"]
        require(set(report.get("resolved_ips", [])) == {cluster_ip}, "Name must resolve to the catalog-api Service")
        api_name = self.pod("catalog-api")["metadata"]["name"]
        require(report.get("response", {}).get("backend") == api_name,
                "The fresh job must be served by the current dependency API Pod")
        print(json.dumps(report, indent=2))
        return True

    def validate(self, log_name=None):
        # Reads resources and runs fresh diagnostic requests; never patches or repairs.
        failures = []
        for title, action in (("Original workloads, configuration mechanism, and DNS settings", self.structure),
                              ("Fresh worker job resolves the Service and completes", self.check_job)):
            try:
                action()
                print(f"PASS: {title}", flush=True)
            except (LabError, KeyError, ValueError, TypeError) as error:
                failures.append(f"FAIL: {title}: {error}")
                print(failures[-1], flush=True)
        if log_name:
            (STATE / log_name).write_text(json.dumps({"failures": failures}, indent=2) + "\n")
        print("Recovery incomplete." if failures else "Recovery checks passed. Complete your short incident handover.")
        return 1 if failures else 0

    def wait_for(self, description, action, seconds=60):
        deadline = time.monotonic() + seconds
        last = "condition not met"
        while time.monotonic() < deadline:
            try:
                if action():
                    return
            except LabError as error:
                last = str(error)
            time.sleep(2)
        raise LabError(f"Timed out waiting for {description}: {last}")

    def setup(self, reset):
        if self.namespace() or STATE.exists():
            require(reset, "Lab/state already exists. Resume it or use setup.sh --reset to discard scenario 03")
            self.cleanup()
        require(self.namespace(WRONG_NS) is None,
                f"Namespace {WRONG_NS} already exists; use a fresh playground for a deterministic exercise")
        nodes = json.loads(self.k("get", "nodes", "-o", "json", namespaced=False).stdout)
        require(any(c.get("type") == "Ready" and c.get("status") == "True"
                    for n in nodes["items"] for c in n.get("status", {}).get("conditions", [])),
                "No Ready node found; wait for the playground")
        STATE.mkdir(mode=0o700)
        self.session = {"context": self.context, "prepared": False}
        self.save()
        self.k("create", "-f", "-", namespaced=False, data=json.dumps({
            "apiVersion": "v1", "kind": "Namespace", "metadata": {
                "name": NS, "labels": {LABEL: OWNER}}}))
        self.session["uid"] = self.namespace()["metadata"]["uid"]
        self.save()
        print(f"Preparing scenario 03 in {NS}; waiting for images and workloads...", flush=True)
        self.config("dns-lab-code", self.code_data())
        self.config("worker-settings", {"DEPENDENCY_HOST": GOOD_HOST})
        self.k("apply", "-f", LAB / "manifests/workloads.yaml")
        self.rollout("catalog-api")
        self.rollout("job-worker")
        self.wait_for("a successful baseline job", self.check_job)
        require(self.validate("baseline-validation.json") == 0,
                "Healthy baseline failed; no incident has been injected")
        # Exactly one changed setting. New Pods are required for ConfigMap-backed env vars.
        self.config("worker-settings", {"DEPENDENCY_HOST": BAD_HOST})
        self.restart_worker()

        def broken():
            process, report = self.attempt()
            (STATE / "incident-job.json").write_text(json.dumps(report, indent=2) + "\n")
            return process.returncode == 1 and report.get("error") == "DNS_ERROR" and report.get("host") == BAD_HOST

        self.wait_for("the intended name-resolution error", broken)
        self.structure()
        require(self.validate("broken-validation.json") == 1, "Broken exercise unexpectedly passed validation")
        self.session["prepared"] = True
        self.save()
        self.task()

    def task(self):
        require(self.session.get("prepared"), "Setup has not finished; inspect errors and reset after fixing prerequisites")
        print(f"\nScenario 03: sample automation jobs fail with name-resolution errors.\nNamespace: {NS}")
        print("\nSystem: a fictional automation worker asks a dependency API to complete a sample calculation.")
        print("Intended path: job-worker Pod -> catalog-api Service:8080 -> catalog-api Pod.")
        print(f"Both Deployments and the Service belong to namespace {NS}.")
        print("The worker reads DEPENDENCY_HOST from ConfigMap worker-settings when its container starts.")
        print("request.sh runs one fresh job inside that worker using its current environment; it is not a separate client configuration.")
        print("In its JSON output, host is the worker's configured destination; nonce is a fresh request ID echoed by the API.")
        print("Success means the API completes the job and returns the matching request ID and sample result.\n")
        print("The dependency is running. Investigate from the worker's network context and restore jobs using DNS.")
        print("Keep the supplied workloads, source code, Service, and worker-settings configuration mechanism.")
        print("Do not hard-code IPs, add host aliases, or change shared DNS/other scenarios.")
        print("Reproduce: bash request.sh\nEvidence: bash inspect.sh\nValidate: bash validate.sh")
        print("Hints: bash hint.sh 1 (then 2 or 3). Reference repair: bash solution.sh")
        print("Handover: impact, evidence, cause, repair, verification, prevention/escalation.")

    def request(self):
        process, report = self.attempt()
        print(json.dumps(report, indent=2))
        if process.stderr.strip():
            print(process.stderr.strip(), file=sys.stderr)
        return 0 if process.returncode == 0 else 1

    def inspect(self):
        for title, args in (
            ("Workloads and dependency Service", ("get", "deployments,pods,services", "-o", "wide")),
            ("Configured worker settings", ("get", "configmap", "worker-settings", "-o", "yaml")),
            ("Worker deployment", ("get", "deployment", "job-worker", "-o", "yaml")),
            ("Dependency endpoints", ("get", "endpointslices", "-l", "kubernetes.io/service-name=catalog-api", "-o", "wide")),
            ("Worker logs", ("logs", "deployment/job-worker", "--tail=12")),
        ):
            print(f"\n{title}", flush=True)
            print(self.k(*args).stdout)
        print("\nWorker resolver configuration", flush=True)
        print(self.execute("cat", "/etc/resolv.conf").stdout)
        print("Worker /etc/hosts", flush=True)
        print(self.execute("cat", "/etc/hosts").stdout)

    def solution(self):
        require(self.session.get("prepared"), "Reference repair requires a fully prepared exercise")
        print("Repairing the worker's dependency setting and replacing the worker Pod...", flush=True)
        self.k("patch", "configmap", "worker-settings", "--type=merge", "-p",
               json.dumps({"data": {"DEPENDENCY_HOST": GOOD_HOST}}))
        self.restart_worker()
        self.wait_for("a successful job after repair", self.check_job)
        return self.validate()

    def cleanup(self):
        if self.namespace():
            self.owned()
            self.k("delete", "namespace", NS, "--wait=true", "--timeout=120s",
                   "--request-timeout=0", namespaced=False, timeout=135)
        if STATE.exists():
            require(not STATE.is_symlink() and STATE.resolve() == LAB / ".state", "Unsafe local state path")
            shutil.rmtree(STATE)
        self.session = {}
        print("Scenario 03 resources and local state removed. Other scenarios were not changed.")


def hint(level):
    print("1. Read the worker's exact error and inspect its actual resolver configuration. Is DNS failing globally or for one name?")
    if level >= 2:
        print("2. Compare the configured dependency hostname with the Service name and namespace. Test both from the worker Pod.")
    if level >= 3:
        print(f"3. worker-settings uses the wrong namespace in DEPENDENCY_HOST. The intended Service is {GOOD_HOST}.")
        print("ConfigMap-backed environment variables require a new Pod after changing the ConfigMap. See solution.sh if stuck.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("setup")
    setup.add_argument("--reset", action="store_true")
    hints = commands.add_parser("hint")
    hints.add_argument("level", nargs="?", type=int, choices=(1, 2, 3), default=1)
    for name in ("task", "request", "inspect", "validate", "solution", "cleanup"):
        commands.add_parser(name)
    args = parser.parse_args()
    if args.command == "hint":
        hint(args.level)
        return 0
    os.umask(0o077)
    lab = Lab()
    lab.connect()
    if args.command == "setup":
        lab.setup(args.reset)
        return 0
    if args.command == "cleanup":
        lab.cleanup()
        return 0
    lab.owned()
    if args.command == "task":
        lab.task()
        return 0
    if args.command == "inspect":
        lab.inspect()
        return 0
    return getattr(lab, args.command)()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (LabError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}\nA failed setup is not a ready exercise. Inspect events/logs and reset after fixing the cause.", file=sys.stderr)
        sys.exit(2)
