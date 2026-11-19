#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-07
OWNER=worker-resources-07
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    printf '\nScenario 07 · Reporting jobs stopped completing\nNamespace %s\n\n' "$LAB_NS"
    if [[ "$(cat "$STATE_DIR/prepared")" == oom ]]; then
        printf 'The workers keep restarting after a capacity change.\n'
    else
        printf 'Replacement workers have been Pending since the last rollout.\n'
    fi
    cat <<'TICKET'

Reporting staff send a sample batch through batch-worker:80. Two worker Pods
listen on port 8080. A successful batch processes 8 items and returns total 36.

Get both workers Ready and restore the job. Keep the image, job code and
Service. Use no more than 128Mi of memory per worker. Leave the nodes alone.

Run bash request.sh to try the batch from batch-client. Use bash validate.sh
to check your fix. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}

case_name() {
    case "$1" in oom|pending) ;; *) die "Choose oom or pending." ;; esac
}

if [[ "${1:-}" == fault && "${2:-}" == --list && $# -eq 2 ]]; then
    printf 'oom\npending\n'
    exit
fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

request() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec pod/batch-client -- python -c '
import json
import urllib.request
with urllib.request.urlopen("http://batch-worker/api/batch", timeout=4) as reply:
    result = json.load(reply)
    print(result)
    if result != {"processed": 8, "total": 36}:
        raise SystemExit("Unexpected batch result")
'
}
request_ok() { request >/dev/null 2>&1; }

validate() {
    kn get deployment batch-worker -o json | python3 -c '
import json
import re
import sys

d = json.load(sys.stdin)
status = d["status"]
worker = d["spec"]["template"]["spec"]["containers"][0]
limit = worker.get("resources", {}).get("limits", {}).get("memory", "")
match = re.fullmatch(r"([0-9]+)Mi", limit)
if (d["spec"]["replicas"] != 2 or status.get("readyReplicas") != 2
        or status.get("updatedReplicas") != 2 or status.get("observedGeneration") != d["metadata"]["generation"]):
    raise SystemExit("FAIL: Two updated worker replicas must be Ready.")
if not (match and 64 <= int(match[1]) <= 128):
    raise SystemExit("FAIL: Keep the worker memory limit between 64Mi and 128Mi.")
if (worker["image"] != "python:3.12.16-alpine3.24"
        or worker.get("command") != ["python", "-u", "/app/worker.py"]
        or not worker.get("readinessProbe")):
    raise SystemExit("FAIL: Keep the supplied worker image, command and health check.")
' || return 1
    request || return 1
    printf 'PASS: Two workers are Ready and the sample batch completed.\n'
}

healthy() {
    rm -f -- "$STATE_DIR/prepared"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    kn patch deployment batch-worker --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
    kn wait --for=condition=Ready pod/batch-client --timeout=180s --request-timeout=0
    rollout batch-worker
    retry 10 2 validate || die "Baseline check failed. No incident was injected."
}

oom_visible() {
    local reasons
    reasons="$(kn get pods -l app=batch-worker -o 'jsonpath={range .items[*]}{range .status.containerStatuses[*]}{.state.terminated.reason}{" "}{.lastState.terminated.reason}{"\n"}{end}{end}')"
    [[ "$reasons" == *OOMKilled* ]]
}

pending_visible() {
    local status
    status="$(kn get pods -l app=batch-worker -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="PodScheduled")].reason}{"\n"}{end}')"
    [[ "$status" == *Unschedulable* ]]
}

inject() {
    local matching_nodes
    case "$1" in
        oom)
            kn set resources deployment/batch-worker -c worker --limits=cpu=200m,memory=24Mi
            retry 30 2 oom_visible || die "The expected memory termination did not appear."
            ;;
        pending)
            matching_nodes="$(k get nodes -l 'training.example.com/worker-pool=retired-07' -o name)" ||
                die "Cannot inspect node labels."
            [[ -z "$matching_nodes" ]] || die "The demonstration node label is already present."
            kn patch deployment batch-worker --type=merge \
                -p '{"spec":{"template":{"spec":{"nodeSelector":{"training.example.com/worker-pool":"retired-07"}}}}}'
            retry 30 2 pending_visible || die "The expected scheduling failure did not appear."
            ;;
    esac
    if validate >/dev/null 2>&1; then die "Expected recovery validation to fail."; fi
    printf '%s\n' "$1" > "$STATE_DIR/prepared"
    ticket
}

setup() {
    local selected=oom
    if [[ $# -gt 0 && "$1" != --reset ]]; then selected="$1"; shift; fi
    case_name "$selected"
    create_namespace "$@"
    kn create configmap batch-code --from-file="worker.py=$LAB_DIR/app/worker.py" --dry-run=client -o yaml | kn apply -f -
    healthy
    inject "$selected"
}

hint() {
    case "$(cat "$STATE_DIR/prepared"):${1:-1}" in
        oom:1) printf 'Describe a restarting worker. What was the last termination reason?\n' ;;
        oom:2) printf 'Look at the memory limit, then compare it with how much memory the job needs.\n' ;;
        oom:3) printf 'Give the worker enough room to start. The previous limit was 96Mi.\n' ;;
        pending:1) printf 'Describe a Pending worker and read the scheduler message under Events.\n' ;;
        pending:2) printf 'Compare the Deployment node selector with the labels on the available nodes.\n' ;;
        pending:3) printf 'Remove the retired worker-pool selector from the Deployment template.\n' ;;
        *) die "Choose hint level 1, 2 or 3." ;;
    esac
}

solution() {
    if [[ "$(cat "$STATE_DIR/prepared")" == oom ]]; then
        kn set resources deployment/batch-worker -c worker --limits=cpu=200m,memory=96Mi
    else
        kn patch deployment batch-worker --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
    fi
    rollout batch-worker
    retry 10 2 validate || die "The reference repair did not pass validation."
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    fault) [[ $# -eq 1 ]] || die "Usage: bash fault.sh [oom|pending|--list]"; case_name "$1"; owned; healthy; inject "$1" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"; require_prepared; hint "$@" ;;
    ticket|request|validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
