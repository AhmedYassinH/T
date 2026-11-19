#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-21
OWNER=incident-rehearsal-21
source "$LAB_DIR/../lib/practice.sh"
connect

probe() {
    timeout 15s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=12s \
        exec deployment/telemetry-api -- python /app/probe.py "$@"
}

probe_is() {
    local action="$1" expected="$2" result
    shift 2
    result="$(probe "$action" "$@" 2>&1)" && [[ "$result" == $expected ]]
}

new_job() { python3 -c 'import uuid; print(uuid.uuid4().hex[:12])'; }

job_state() { printf '200 {"job": "%s", "state": "%s"}' "$1" "$2"; }

portal_result='200 {"pressure": 210.5, "sensor": "well-17"}'

worker_host() {
    kn patch configmap worker-settings --type=merge -p "{\"data\":{\"JOB_HOST\":\"$1\"}}"
    kn rollout restart deployment/job-worker
    rollout job-worker
}

ticket() {
    local job
    job="$(cat "$STATE_DIR/prepared")"
    cat <<TICKET

Scenario 21 · Readings and jobs fail after maintenance
Namespace $LAB_NS

Field staff can’t load the latest reading or finish an existing job.
Normal paths: operations-portal → telemetry-api for readings, and
job-worker → telemetry-api for job completion. The Services listen on port 80.

Restore the reading for well-17 and job $job. Keep the API Pod
running so its saved jobs survive. Run bash request.sh to see both symptoms,
then bash validate.sh to check the reading and finish the old job and a new one.

Give a one-minute handover: impact, what you found, what changed, and your checks.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}

setup() {
    local baseline job
    command -v python3 >/dev/null || die "Missing python3."
    create_namespace "$@"
    kn create configmap rehearsal-code \
        --from-file="$LAB_DIR/tools/service.py" --from-file="$LAB_DIR/tools/probe.py"
    kn apply -f "$LAB_DIR/manifests/stack.yaml"
    rollout telemetry-api
    rollout operations-portal
    rollout job-worker

    retry 12 2 probe_is portal "$portal_result" || die "The baseline portal did not return the reading."
    baseline="$(new_job)"
    retry 12 2 probe_is submit "$(job_state "$baseline" pending)" "$baseline" ||
        die "Could not seed a baseline job."
    retry 12 2 probe_is run "$(job_state "$baseline" completed)" "$baseline" ||
        die "The baseline worker could not finish the job."
    probe_is status "$(job_state "$baseline" completed)" "$baseline" ||
        die "The API did not record the baseline completion."
    job="$(new_job)"
    probe_is submit "$(job_state "$job" pending)" "$job" || die "Could not seed the incident job."

    kn patch service operations-portal --type=json \
        -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8099}]'
    worker_host telemetry-api-retired

    retry 12 2 probe_is portal '000 *' || die "The expected portal connection failure did not appear."
    retry 12 2 probe_is run '503 {"backend": "telemetry-api-retired", "error": "DNS lookup failed"}' "$job" ||
        die "The expected worker DNS failure did not appear."
    probe_is status "$(job_state "$job" pending)" "$job" || die "The incident job must still exist and stay pending."
    printf '%s\n' "$job" > "$STATE_DIR/prepared"
    ticket
}

request() {
    local job rc=0
    job="$(cat "$STATE_DIR/prepared")"
    printf 'Portal reading · '
    probe portal || rc=1
    printf 'Worker completion · '
    probe run "$job" || rc=1
    printf 'Saved job status · '
    probe status "$job" || rc=1
    return "$rc"
}

check_job() {
    local job="$1"
    probe_is run "$(job_state "$job" completed)" "$job" &&
        probe_is status "$(job_state "$job" completed)" "$job"
}

validate() {
    local job fresh rc=0
    command -v python3 >/dev/null || die "Missing python3."
    job="$(cat "$STATE_DIR/prepared")"
    if probe_is portal "$portal_result"; then
        printf 'PASS: The portal returns the saved reading.\n'
    else
        printf 'FAIL: The portal did not return the saved reading.\n'
        rc=1
    fi
    if check_job "$job"; then
        printf 'PASS: The worker completed the original job.\n'
    else
        printf 'FAIL: The worker could not complete the original job.\n'
        rc=1
    fi
    fresh="$(new_job)"
    if probe_is submit "$(job_state "$fresh" pending)" "$fresh" && check_job "$fresh"; then
        printf 'PASS: A new job also completed.\n'
    else
        printf 'FAIL: A new job could not complete.\n'
        rc=1
    fi
    return "$rc"
}

hint() {
    case "${1:-1}" in
        1) printf 'Trace the reading and job requests separately. Which request reaches its first Pod?\n' ;;
        2) printf 'Compare the portal Service port with its Pod listener, then look for the hostname in the worker logs.\n' ;;
        3) printf 'Route the portal Service to port http. Point JOB_HOST at telemetry-api and restart the worker.\n' ;;
        *) die "Choose hint level 1, 2 or 3." ;;
    esac
}

solution() {
    kn patch service operations-portal --type=json \
        -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
    worker_host telemetry-api
    retry 12 2 probe_is portal "$portal_result" || die "The repaired portal route did not converge."
    validate
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request|ticket|validate|solution)
        [[ $# -eq 0 ]] || die "Unexpected arguments."
        require_prepared
        "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"; require_prepared; hint "$@" ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
