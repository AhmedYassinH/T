#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-05
OWNER=container-startup-05
APP=reading-collector
IMAGE=python:3.12.16-alpine3.24
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Support ticket 05 · Replacement readings container does not come up

Field operators use a collector to confirm which well station their readings
belong to. In namespace kappa-practice-05 the path is:

  collector-client Pod -> reading-collector Service:80 -> collector Pod:8080

The collector normally serves GET /api/station and returns status=ok with
station=well-17. Its source is mounted from collector-code, and its station
ID comes from collector-settings as an environment variable at container
startup. The Deployment specifies the image and health probes. The approved
base image is python:3.12.16-alpine3.24 and the Service stays on port 80.

After a replacement rollout, the collector is unavailable. Diagnose why the
container does not become ready. Inspect Pod states, events and logs, and
compare what the container needs with what the Deployment supplies.
Keep the approved image, configuration source, probes and Service route.

  bash request.sh    Request the station data from inside collector-client.
  bash validate.sh   Verify readiness, intended configuration and live HTTP.
  bash hint.sh 1     Get a hint. Use 2 or 3 for more detail.
  bash solution.sh   Apply the selected case's reference repair.
  bash cleanup.sh    Remove this exercise.

Give a short handover with impact, evidence, repair and recovery checks.
TICKET
}

select_fault() {
    case "$1" in config|image) ;; *) die "Choose config or image." ;; esac
}

case "${1:-}" in
    task) [[ $# -eq 1 ]] || die "Usage: bash task.sh"; ticket; exit ;;
    fault)
        if [[ "${2:-}" == --list && $# -eq 2 ]]; then
            printf 'config\nimage\n'
            exit
        fi
        ;;
esac

connect

request() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec pod/collector-client -- python -c '
import json
import urllib.request

url = "http://reading-collector/api/station"
with urllib.request.urlopen(url, timeout=4) as response:
    payload = json.load(response)
    print(json.dumps(payload))
    if response.status != 200 or payload != {"status": "ok", "station": "well-17"}:
        raise SystemExit("Unexpected HTTP response")
'
}

request_ok() { request >/dev/null 2>&1; }

healthy() {
    rm -f -- "$STATE_DIR/prepared"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    kn wait --for=condition=Ready pod/collector-client --timeout=180s --request-timeout=0
    kn rollout restart "deployment/$APP"
    rollout "$APP"
    retry 10 2 request_ok || die "Baseline HTTP check failed. No incident was injected."
}

waiting_for() {
    local states
    states="$(kn get pods -l "app=$APP" -o 'jsonpath={range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}')"
    [[ "$states" =~ $1 ]]
}

inject() {
    local waiting
    case "$1" in
        config)
            kn patch configmap collector-settings --type=json -p='[{"op":"remove","path":"/data/station-id"}]'
            kn rollout restart "deployment/$APP"
            waiting=CreateContainerConfigError
            ;;
        image)
            kn set image "deployment/$APP" collector=python:3.12.16-kappa-05-missing-tag
            waiting=ImagePullBackOff
            ;;
    esac
    retry 45 2 waiting_for "$waiting" || die "Expected Pod startup failure did not appear. Setup is incomplete."
    if request_ok; then die "HTTP still works. The intended failure was not reproduced."; fi
    printf '%s\n' "$1" > "$STATE_DIR/prepared"
    ticket
}

setup() {
    local fault=config
    if [[ $# -gt 0 && "$1" != --reset ]]; then
        fault="$1"
        shift
    fi
    select_fault "$fault"
    create_namespace "$@"
    kn create configmap collector-code --from-file="collector.py=$LAB_DIR/app/collector.py" --dry-run=client -o yaml | kn apply -f -
    healthy
    inject "$fault"
}

validate() {
    local state
    state="$(kn get deploy "$APP" -o 'jsonpath={.spec.replicas}|{.status.readyReplicas}|{.spec.template.spec.containers[0].image}|{.spec.template.spec.containers[0].env[0].valueFrom.configMapKeyRef.name}|{.spec.template.spec.containers[0].env[0].valueFrom.configMapKeyRef.key}|{.spec.template.spec.containers[0].readinessProbe.httpGet.path}|{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')" || die "Cannot inspect collector Deployment."
    if [[ "$state" != "1|1|$IMAGE|collector-settings|station-id|/healthz|/healthz" ]]; then
        printf 'FAIL: The collector must be ready with its approved image, configuration and probes.\n'
        return 1
    fi
    request || return 1
    printf 'PASS: The prepared collector serves the expected station through the Service.\n'
}

hint() {
    case "${1:-1}" in
        1) printf 'Check Pod waiting reasons and events. Did the container ever start?\n' ;;
        2)
            case "$(cat "$STATE_DIR/prepared")" in
                config) printf 'Compare the required ConfigMap reference with the live ConfigMap data.\n' ;;
                image) printf 'Inspect the image pull event and compare the tag with the approved image.\n' ;;
            esac ;;
        3)
            case "$(cat "$STATE_DIR/prepared")" in
                config) printf 'Restore data.station-id=well-17 in collector-settings. The kubelet can retry container creation.\n' ;;
                image) printf 'Restore the collector container image to %s.\n' "$IMAGE" ;;
            esac ;;
        *) die "Choose hint level 1, 2 or 3." ;;
    esac
}

solution() {
    case "$(cat "$STATE_DIR/prepared")" in
        config)
            kn patch configmap collector-settings --type=merge -p '{"data":{"station-id":"well-17"}}'
            ;;
        image) kn set image "deployment/$APP" "collector=$IMAGE" ;;
        *) die "Invalid saved scenario case." ;;
    esac
    rollout "$APP"
    retry 10 2 request_ok || die "The reference fix did not restore HTTP."
    validate
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    fault)
        [[ $# -eq 1 ]] || die "Usage: bash fault.sh [config|image|--list]"
        select_fault "$1"
        owned
        healthy
        inject "$1"
        ;;
    hint)
        [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        require_prepared
        hint "$@"
        ;;
    request|validate|solution)
        [[ $# -eq 0 ]] || die "Unexpected arguments for $command."
        require_prepared
        "$command"
        ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
