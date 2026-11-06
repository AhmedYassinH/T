"""Inspect a kubectl JSON snapshot; never modify the cluster."""

import json
import sys
from pathlib import Path


def main():
    snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    lab_dir = Path(sys.argv[2])
    items = snapshot["items"]
    objects = {(item["kind"], item["metadata"]["name"]): item for item in items}
    pods = [p for p in items if p["kind"] == "Pod" and not p["metadata"].get("deletionTimestamp")]
    api_pods = [p for p in pods if p["metadata"].get("labels", {}).get("app") == "portal-api"]
    if len(sys.argv) == 4 and sys.argv[3] == "--backends":
        for pod in api_pods:
            print(f"{pod['metadata']['name']}|{pod.get('status', {}).get('podIP', '')}")
        return 0

    failures = 0

    def check(description, passed):
        nonlocal failures
        print(f"{'PASS' if passed else 'FAIL'}: {description}")
        if not passed:
            failures += 1

    def ready(pod):
        return any(c.get("type") == "Ready" and c.get("status") == "True"
                   for c in pod.get("status", {}).get("conditions", []))

    for name, replicas in (("portal-api", 2), ("portal-gateway", 1)):
        deployment = objects.get(("Deployment", name), {})
        spec, status = deployment.get("spec", {}), deployment.get("status", {})
        healthy = (
            bool(deployment)
            and spec.get("replicas") == replicas
            and status.get("observedGeneration", 0) >= deployment.get("metadata", {}).get("generation", 1)
            and all(status.get(key, 0) == replicas for key in
                    ("replicas", "updatedReplicas", "readyReplicas", "availableReplicas"))
        )
        check(f"{name} retains {replicas} ready, updated replicas", healthy)
        containers = spec.get("template", {}).get("spec", {}).get("containers", [])
        check(f"{name} retains HTTP readiness and liveness probes",
              bool(containers) and all(
                  c.get("readinessProbe", {}).get("httpGet", {}).get("path") == "/healthz"
                  and c.get("livenessProbe", {}).get("httpGet", {}).get("path") == "/healthz"
                  for c in containers))

    check("Two API pods are ready", len(api_pods) == 2 and all(ready(p) for p in api_pods))
    check("Diagnostic client is ready", ready(objects.get(("Pod", "lab-client"), {})))

    for name, expected_label in (("portal-api", "portal-api"), ("portal-gateway", "portal-gateway")):
        service = objects.get(("Service", name), {}).get("spec", {})
        ports = service.get("ports", [])
        check(f"{name} remains a ClusterIP Service exposing TCP port 80",
              service.get("type") == "ClusterIP" and len(ports) == 1
              and ports[0].get("port") == 80 and ports[0].get("protocol", "TCP") == "TCP")
        selector = service.get("selector", {})
        selected = [p for p in pods if selector and all(
            p["metadata"].get("labels", {}).get(key) == value for key, value in selector.items())]
        expected = [p for p in pods if p["metadata"].get("labels", {}).get("app") == expected_label]
        check(f"{name} selects exactly its intended pods",
              bool(expected) and {p["metadata"]["name"] for p in selected}
              == {p["metadata"]["name"] for p in expected})

        target = ports[0].get("targetPort", ports[0].get("port")) if len(ports) == 1 else None
        resolved = []
        for pod in selected:
            port = target
            if isinstance(target, str):
                matches = [p.get("containerPort") for c in pod["spec"].get("containers", [])
                           for p in c.get("ports", []) if p.get("name") == target
                           and p.get("protocol", "TCP") == "TCP"]
                port = matches[0] if len(matches) == 1 else None
            resolved.append(port)
        check(f"{name} Service target resolves to its application listener",
              bool(resolved) and all(port == 8080 for port in resolved))

    slices = [i for i in items if i["kind"] == "EndpointSlice" and
              i["metadata"].get("labels", {}).get("kubernetes.io/service-name") == "portal-api"]
    addresses = set()
    slice_ports_valid = bool(slices)
    for item in slices:
        ports = item.get("ports", [])
        slice_ports_valid = slice_ports_valid and bool(ports) and all(p.get("port") == 8080 for p in ports)
        for endpoint in item.get("endpoints", []):
            if endpoint.get("conditions", {}).get("ready") is True:
                addresses.update(endpoint.get("addresses", []))
    # A dual-stack pod can still be selected by a single-stack IPv4 Service.
    families = objects.get(("Service", "portal-api"), {}).get("spec", {}).get("ipFamilies", ["IPv4"])
    expected_addresses = {
        ip["ip"] for p in api_pods for ip in p.get("status", {}).get("podIPs", [])
        if ("IPv6" if ":" in ip["ip"] else "IPv4") in families
    }
    check("API EndpointSlices contain the ready backend addresses and listener port",
          slice_ports_valid and bool(expected_addresses) and addresses == expected_addresses)

    for name, key, source in (("portal-api-code", "app.py", lab_dir / "app/app.py"),
                              ("portal-gateway-config", "nginx.conf", lab_dir / "manifests/gateway.conf")):
        actual = objects.get(("ConfigMap", name), {}).get("data", {}).get(key)
        check(f"{name} retains the supplied application/proxy configuration",
              actual == source.read_text(encoding="utf-8"))
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f"Snapshot inspection error: {error}", file=sys.stderr)
        sys.exit(2)
