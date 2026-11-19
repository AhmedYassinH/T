#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-06
OWNER=stalled-rollout-06
APP=operations-dashboard
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 06 · The dashboard update isn't live
Namespace kappa-practice-06

Field staff check the active dashboard release at GET /api/status.
dashboard-client -> operations-dashboard:80 -> two dashboard Pods:8080
The response names the release and Pod. Each Pod reads dashboard-settings
at startup. Keep both replicas, their probes and the existing Service.

Run bash request.sh to ask the Service what is live.
Use bash validate.sh to check both replicas. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
    if [[ "$(cat "$STATE_DIR/prepared")" == probe ]]; then
        printf '\nThe rollout stalled after maintenance. Users can still reach v1. Restore two ready replicas.\n'
    else
        printf '\nRelease v2 was approved, but requests still show v1. Finish the update so both Pods serve v2.\n'
    fi
}

case_name() {
    case "$1" in probe|mounted) ;; *) die "Choose probe or mounted." ;; esac
}

if [[ "${1:-}" == fault && "${2:-}" == --list && $# -eq 2 ]]; then
    printf 'probe\nmounted\n'
    exit
fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

request() {
    local base="http://operations-dashboard"
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec pod/dashboard-client -- python -c '
import json
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1] + "/api/status", timeout=4) as response:
    payload = json.load(response)
    print(json.dumps(payload))
    if response.status != 200 or payload.get("status") != "ok" or not payload.get("pod"):
        raise SystemExit("Unexpected HTTP response")
    if len(sys.argv) == 3 and payload.get("release") != sys.argv[2]:
        raise SystemExit("Unexpected configuration release")
' "$base" "$@"
}

request_ok() { request "$1" >/dev/null 2>&1; }

reconcile_baseline() {
    rm -f -- "$STATE_DIR/prepared"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    kn wait --for=condition=Ready pod/dashboard-client --timeout=180s --request-timeout=0
    kn rollout restart "deployment/$APP"
    rollout "$APP"
    retry 10 2 request_ok v1 || die "The v1 baseline did not respond through the Service."
}

probe_fault_visible() {
    local counts messages
    counts="$(kn get deploy "$APP" -o 'jsonpath={.status.updatedReplicas}|{.status.readyReplicas}')"
    [[ "$counts" == '1|2' ]] || return 1
    messages="$(kn get events --field-selector reason=Unhealthy -o 'jsonpath={range .items[*]}{.message}{"\n"}{end}')"
    [[ "$messages" == *'Readiness probe failed: HTTP probe failed with statuscode: 404'* ]] && request_ok v1
}

inject() {
    case "$1" in
        probe)
            kn patch deployment "$APP" --type=json \
                -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready-v2"}]'
            retry 30 2 probe_fault_visible || die "The stalled rollout and retained service traffic were not observed."
            ;;
        mounted)
            kn patch configmap dashboard-settings --type=merge -p '{"data":{"release.json":"{\"release\":\"v2\"}"}}'
            request_ok v1 || die "The saved update did not leave the expected v1 response."
            ;;
    esac
    printf '%s\n' "$1" > "$STATE_DIR/prepared"
    ticket
}

setup() {
    local selected=probe
    if [[ $# -gt 0 && "$1" != --reset ]]; then
        selected="$1"
        shift
    fi
    case_name "$selected"
    create_namespace "$@"
    kn create configmap dashboard-code --from-file="dashboard.py=$LAB_DIR/app/dashboard.py" --dry-run=client -o yaml | kn apply -f -
    reconcile_baseline
    inject "$selected"
}

validate() {
    local expected=v1 status config pods name ip observed=0
    local desired current updated ready readiness liveness generation observed_generation
    [[ "$(cat "$STATE_DIR/prepared")" != mounted ]] || expected=v2
    status="$(kn get deploy "$APP" -o 'jsonpath={.spec.replicas}|{.status.replicas}|{.status.updatedReplicas}|{.status.readyReplicas}|{.spec.template.spec.containers[0].readinessProbe.httpGet.path}|{.spec.template.spec.containers[0].livenessProbe.httpGet.path}|{.metadata.generation}|{.status.observedGeneration}')"
    IFS='|' read -r desired current updated ready readiness liveness generation observed_generation <<< "$status"
    if [[ "$desired|$current|$updated|$ready|$readiness|$liveness" != '2|2|2|2|/readyz|/livez' || "$generation" != "$observed_generation" ]]; then
        printf 'FAIL: Two updated and ready replicas with the required probes must converge.\n'
        return 1
    fi
    config="$(kn get configmap dashboard-settings -o 'jsonpath={.data.release\.json}')"
    if [[ "$config" != "{\"release\":\"$expected\"}" ]]; then
        # The API accepts equivalent JSON formatting. Evaluate the object downstream per Pod.
        if ! printf '%s' "$config" | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin) != {"release":sys.argv[1]})' "$expected"; then
            printf 'FAIL: Keep the approved release %s in dashboard-settings.\n' "$expected"
            return 1
        fi
    fi
    request "$expected" || return 1
    pods="$(kn get pods -l "app=$APP" -o json | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    if not pod["metadata"].get("deletionTimestamp"):
        print(pod["metadata"]["name"], pod["status"].get("podIP", ""))
')"
    while read -r name ip; do
        [[ -n "$name" && -n "$ip" ]] || return 1
        if [[ "$ip" == *:* ]]; then ip="[$ip]"; fi
        timeout 10s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=8s \
            exec pod/dashboard-client -- python -c '
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:8080/api/status", timeout=4) as response:
    result = json.load(response)
    sys.exit(result.get("release") != sys.argv[2] or result.get("pod") != sys.argv[3])
' "$ip" "$expected" "$name" || { printf 'FAIL: %s did not serve %s.\n' "$name" "$expected"; return 1; }
        ((observed+=1))
    done <<< "$pods"
    [[ "$observed" -eq 2 ]] || { printf 'FAIL: Expected two live dashboard Pods.\n'; return 1; }
    printf 'PASS: Both updated dashboard Pods and the Service serve %s.\n' "$expected"
}

hint() {
    case "${1:-1}" in
        1) printf 'Run bash request.sh and check rollout status. Are users still reaching the previous release?\n' ;;
        2)
            if [[ "$(cat "$STATE_DIR/prepared")" == probe ]]; then
                printf 'Look at the new Pod events. Which readiness URL is failing?\n'
            else
                printf 'Compare the ConfigMap with /config/release.json inside a Pod. Do they show the same release?\n'
            fi ;;
        3)
            if [[ "$(cat "$STATE_DIR/prepared")" == probe ]]; then
                printf 'Point readiness at /readyz or roll back to the working revision.\n'
            else
                printf 'Keep v2 in the ConfigMap and restart the Deployment so new Pods mount and read it.\n'
            fi ;;
        *) die "Choose hint level 1, 2 or 3." ;;
    esac
}

solution() {
    if [[ "$(cat "$STATE_DIR/prepared")" == probe ]]; then
        kn patch deployment "$APP" --type=json \
            -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/readyz"}]'
    else
        kn rollout restart "deployment/$APP"
    fi
    rollout "$APP"
    retry 10 2 validate || die "Reference repair did not pass validation."
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    fault)
        [[ $# -eq 1 ]] || die "Usage: bash fault.sh [probe|mounted|--list]"
        case_name "$1"
        owned
        reconcile_baseline
        inject "$1"
        ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"; require_prepared; hint "$@" ;;
    task|request|validate|solution)
        [[ $# -eq 0 ]] || die "Unexpected arguments for $command."
        require_prepared
        if [[ "$command" == task ]]; then ticket; else "$command"; fi
        ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
