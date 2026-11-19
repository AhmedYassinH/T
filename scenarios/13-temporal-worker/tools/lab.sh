#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-13
OWNER=temporal-worker-13
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 13 · Daily reports start but never finish
Namespace kappa-practice-13

The reporting client submits workflows to report-orchestrator:7233. A worker
takes them from daily-reports and should return a sample total of 36.

After a worker update, the server still accepts workflows, but an existing
report is stuck. Restore that run and confirm a new report also finishes.
Keep the Temporal server and its workflow history.

Run bash request.sh to view the existing workflow.
Use bash validate.sh to check recovery. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

flow() {
    timeout 55s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=50s \
        exec deployment/temporal-report-worker -c worker -- python /app/report_flow.py "$@"
}
new_id() { python3 -c 'import uuid; print("report-" + uuid.uuid4().hex)'; }

change_queue() {
    kn patch configmap report-worker-settings --type=merge -p "{\"data\":{\"queue\":\"$1\"}}"
    kn rollout restart deployment/temporal-report-worker
    rollout temporal-report-worker
}

setup() {
    local baseline pending
    create_namespace "$@"
    kn create configmap temporal-demo-code --from-file="report_flow.py=$LAB_DIR/app/report_flow.py" --dry-run=client -o yaml | kn apply -f -
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout report-orchestrator
    rollout temporal-report-worker || die "Worker did not start. Check image pulls and SDK installation."
    baseline="$(new_id)"
    flow start "$baseline"
    flow check "$baseline" || die "The baseline report did not complete."
    change_queue daily-reports-legacy
    pending="$(new_id)"
    flow start "$pending"
    flow pending "$pending" || die "Did not reproduce the interrupted workflow."
    printf '%s\n' "$pending" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local original probe
    original="$(cat "$STATE_DIR/prepared")"
    flow check "$original" || return 1
    probe="$(new_id)"
    flow start "$probe"
    flow check "$probe"
}

solution() { change_queue daily-reports; validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; flow inspect "$(cat "$STATE_DIR/prepared")" ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Run bash request.sh. Is the workflow running, completed, or failed?\n' ;;
            2) printf 'Compare the task queue in that output with the queue the worker says it is polling.\n' ;;
            3) printf 'Set queue to daily-reports in report-worker-settings and restart the worker Deployment.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
