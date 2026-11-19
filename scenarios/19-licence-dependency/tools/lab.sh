#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-19
OWNER=licence-dependency-19
source "$LAB_DIR/../lib/practice.sh"
umask 077
if [[ "${1:-}" == fault && "${2:-}" == --list && $# -eq 2 ]]; then printf 'unreachable\ncapacity\n'; exit; fi
connect

ticket() {
    cat <<'TICKET'
Scenario 19 · The pressure report cannot obtain a licence
Namespace kappa-practice-19

The report asks demo-licence:8080 for a simulated feature lease before it
can run. A healthy job obtains a lease and returns total 36.

The team reports failed jobs after a change. Work out whether the service
is unreachable or rejecting a request that reached it. Restore the report
and keep the licence check. The demo licence has one approved seat.

Run bash request.sh to try the report from inside licensed-report.
Use bash validate.sh after the fix. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}

case_name() {
    case "$1" in unreachable|capacity) ;; *) die "Choose unreachable or capacity." ;; esac
}

report() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec deployment/licensed-report -- python /app/lease_demo.py run "$1"
}

set_endpoint() {
    kn patch configmap feature-settings --type=merge -p "{\"data\":{\"endpoint\":\"$1\"}}"
    kn rollout restart deployment/licensed-report
    rollout licensed-report
}

set_seats() {
    kn patch configmap demo-licence-policy --type=merge -p "{\"data\":{\"seats\":\"$1\"}}"
    kn rollout restart deployment/demo-licence
    rollout demo-licence
}

healthy() {
    rm -f -- "$STATE_DIR/prepared"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    kn rollout restart deployment/demo-licence deployment/licensed-report
    rollout demo-licence
    rollout licensed-report
    retry 10 2 report healthy || die "The baseline could not obtain a demo seat."
}

inject() {
    if [[ "$1" == unreachable ]]; then
        set_endpoint http://demo-licence:8089
    else
        set_seats 0
    fi
    retry 10 2 report "$1" || die "Expected licence incident did not appear."
    printf '%s\n' "$1" > "$STATE_DIR/prepared"
    ticket
}

setup() {
    local selected=unreachable
    if [[ $# -gt 0 && "$1" != --reset ]]; then selected="$1"; shift; fi
    case_name "$selected"
    create_namespace "$@"
    kn create configmap lease-demo-code --from-file="lease_demo.py=$LAB_DIR/app/lease_demo.py" --dry-run=client -o yaml | kn apply -f -
    healthy
    inject "$selected"
}

validate() {
    local settings
    settings="$(kn get configmap feature-settings -o 'jsonpath={.data.endpoint}')"
    [[ "$settings" == http://demo-licence:8080 ]] ||
        { printf 'FAIL: The report must call the approved licence endpoint.\n'; return 1; }
    [[ "$(kn get configmap demo-licence-policy -o 'jsonpath={.data.seats}')" == 1 ]] ||
        { printf 'FAIL: Keep exactly one approved demo seat.\n'; return 1; }
    report healthy
}

solution() {
    if [[ "$(cat "$STATE_DIR/prepared")" == unreachable ]]; then
        set_endpoint http://demo-licence:8080
    else
        set_seats 1
    fi
    retry 10 2 validate || die "The report did not recover."
}

hint() {
    case "$(cat "$STATE_DIR/prepared"):${1:-1}" in
        *:1) printf 'Read the report error. Did the licence service return an HTTP response?\n' ;;
        unreachable:2) printf 'Compare the configured URL with the licence Service and its port.\n' ;;
        unreachable:3) printf 'Restore port 8080 in feature-settings and restart licensed-report.\n' ;;
        capacity:2) printf 'Read the HTTP 409 response. Is this a connectivity or a seat capacity problem?\n' ;;
        capacity:3) printf 'Restore the one approved seat in demo-licence-policy. In a real incident, confirm this with the licence owner.\n' ;;
        *) die "Choose hint level 1, 2 or 3." ;;
    esac
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    fault) [[ $# -eq 1 ]] || die "Usage: bash fault.sh [unreachable|capacity|--list]"; case_name "$1"; owned; healthy; inject "$1" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; report healthy ;;
    ticket|validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"; require_prepared; hint "$@" ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
