#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-10
OWNER=rabbitmq-backlog-10
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 10 · Report jobs pile up
Namespace kappa-practice-10

The portal submits jobs to report-jobs on report-broker:5672. The report-worker
consumes them and publishes a completion for each job to report-results.

The broker still accepts jobs after a worker update, but two queued jobs
have gone nowhere. Restore processing and keep those jobs in the queue
until the worker handles them. Keep the broker and its data.

Run bash request.sh to see queue depth and consumers. Add a sample with
bash request.sh submit. Use bash validate.sh to check the seeded jobs and
a fresh one. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

queue() {
    timeout 50s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=45s \
        exec deployment/report-worker -c worker -- python /app/queue_demo.py "$@"
}

job_id() { python3 -c 'import uuid; print(uuid.uuid4().hex)'; }

change_queue() {
    kn patch configmap report-settings --type=merge -p "{\"data\":{\"work-queue\":\"$1\"}}"
    kn rollout restart deployment/report-worker
    rollout report-worker
}

setup() {
    local id
    create_namespace "$@"
    kn create configmap report-code --from-file="queue_demo.py=$LAB_DIR/app/queue_demo.py" --dry-run=client -o yaml | kn apply -f -
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout report-broker
    rollout report-worker || die "The worker did not start. Check image/PyPI access and the init container logs."
    id="$(job_id)"
    queue publish "baseline-$id"
    queue check "baseline-$id" || die "The healthy baseline did not complete the job."
    change_queue report-archive
    queue publish "$id-seed-1" "$id-seed-2"
    queue incident || die "Could not verify a backlog with no consumer."
    printf '%s\n' "$id" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local id probe
    id="$(cat "$STATE_DIR/prepared")"
    probe="check-$(job_id)"
    queue publish "$probe" && queue check "$id-seed-1" "$id-seed-2" "$probe"
}

solution() {
    change_queue report-jobs
    validate
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request)
        require_prepared
        if [[ $# -eq 0 ]]; then queue status
        elif [[ $# -eq 1 && "$1" == submit ]]; then queue publish "sample-$(job_id)"
        else die "Usage: bash request.sh [submit]"; fi
        ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Run bash request.sh. How many consumers are attached to report-jobs?\n' ;;
            2) printf 'Check the worker logs for the queue it listens to. Where does that setting come from?\n' ;;
            3) printf 'Set work-queue to report-jobs in report-settings, then restart the worker Deployment.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
