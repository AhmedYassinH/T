#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-04
OWNER=database-network-policy-04
source "$LAB_DIR/../lib/practice.sh"
umask 077

print_ticket() {
    cat <<'TICKET'
Scenario 04 · Reports time out after a network change
Namespace kappa-practice-04

The reporting Pod reads pressure data from PostgreSQL:
report-app -> report-db:5432 -> PostgreSQL
A successful report prints 210.5. PostgreSQL is Ready, but the report now
times out after a security rollout.

Restore access for report-app. Keep test-client blocked, and keep the
existing labels, database and Service in place.

Try bash request.sh from this folder to run the report inside report-app.
Use bash request.sh control for the other client and bash validate.sh
to check both paths. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}

case "${1:-}" in
    task)
        [[ $# -eq 1 ]] || die "Usage: bash task.sh"
        print_ticket
        exit
        ;;
    hint)
        [[ $# -le 2 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${2:-1}" in
            1) printf 'Run bash request.sh. Does PostgreSQL reject the login, or does the connection time out?\n' ;;
            2) printf 'Compare the role label on report-app with the source selector in report-db-ingress.\n' ;;
            3) printf 'Allow role=report-reader to reach the database on TCP 5432. Check that test-client stays blocked.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac
        exit
        ;;
esac

connect

query() {
    local pod="$1"
    shift
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec "pod/$pod" -- env "$@" sh /demo/report.sh
}

ok() {
    local result
    result="$(query "$@" 2>&1)" && [[ "$result" == 210.5 ]]
}

blocked() {
    local result rc=0
    result="$(query "$@" 2>&1)" || rc=$?
    # Require libpq's connection failure rather than treating exec/DNS errors as isolation.
    [[ "$rc" -eq 2 && "$result" =~ (timeout[[:space:]]expired|Connection[[:space:]]timed[[:space:]]out|No[[:space:]]route[[:space:]]to[[:space:]]host) ]]
}

database_ok() {
    local result
    result="$(kn exec deploy/report-db -- psql -X -w -A -t -U postgres -d reporting \
        -c 'SELECT pressure_bar FROM well_reading WHERE id = 1;' 2>&1)" && [[ "$result" == 210.5 ]]
}

service_ip() {
    local ip
    ip="$(kn get service report-db -o 'jsonpath={.spec.clusterIP}')" || return 1
    [[ -n "$ip" && "$ip" != None ]] || return 1
    printf '%s\n' "$ip"
}

ready_network() {
    ok report-app && blocked test-client "PGHOSTADDR=$DB_IP" && database_ok
}

validate() {
    local failures=0 db_ip db_pod_ip client_role test_role hosts
    owned
    db_ip="$(service_ip)" || die "The report-db Service must have a ClusterIP."
    db_pod_ip="$(kn get pod -l app=report-db -o 'jsonpath={.items[0].status.podIP}')" || die "Cannot inspect the database Pod."
    [[ -n "$db_pod_ip" ]] || die "The database Pod has no address."
    client_role="$(kn get pod report-app -o 'jsonpath={.metadata.labels.role}')"
    test_role="$(kn get pod test-client -o 'jsonpath={.metadata.labels.role}')"
    hosts="$(kn get pod report-app test-client -o 'jsonpath={range .items[*]}{.spec.hostNetwork}{" "}{end}')"
    if [[ "$client_role" != report-reader || "$test_role" != unrelated || "$hosts" == *true* ]]; then
        printf 'FAIL: Client identities or networking changed.\n'
        failures=1
    fi
    if [[ "$(kn get deployment report-db -o 'jsonpath={.spec.replicas}')" != 1 ]] || ! database_ok; then
        printf 'FAIL: Original database workload or sample record is unavailable.\n'
        failures=1
    fi
    if ok report-app; then
        printf 'PASS: The authorised report reads 210.5 through the named Service.\n'
    else
        printf 'FAIL: The report cannot read the expected record.\n'
        failures=1
    fi
    if blocked test-client "PGHOSTADDR=$db_ip" && blocked test-client "PGHOSTADDR=$db_pod_ip"; then
        printf 'PASS: The unrelated client is blocked at both the Service and the Pod.\n'
    else
        printf 'FAIL: The unrelated client is not demonstrably blocked.\n'
        failures=1
    fi
    return "$failures"
}

setup() {
    create_namespace "$@"
    printf 'Preparing the reporting service in %s.\n' "$LAB_NS"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml" -f "$LAB_DIR/manifests/clients.yaml"
    rollout report-db
    kn wait --for=condition=Ready pod/report-app pod/test-client --timeout=180s --request-timeout=0
    DB_IP="$(service_ip)" || die "Cannot determine report-db Service IP."
    retry 10 2 ok report-app || die "Baseline report failed before adding policy."
    retry 10 2 ok test-client "PGHOSTADDR=$DB_IP" || die "Baseline control client failed before adding policy."
    printf 'Checking that this cluster enforces NetworkPolicy.\n'
    kn apply -f "$LAB_DIR/manifests/policy.yaml"
    if ! retry 10 2 ready_network; then
        die "Could not prove NetworkPolicy enforcement and the allowed report path. Use a policy-capable Kubernetes playground. No incident was injected."
    fi
    kn patch networkpolicy report-db-ingress --type=json \
        -p='[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels/role","value":"report-worker"}]'
    retry 10 2 blocked report-app || die "Could not reproduce the report timeout. Setup is incomplete."
    database_ok && blocked test-client "PGHOSTADDR=$DB_IP" || die "The dependency or control path did not retain the expected state."
    touch "$STATE_DIR/prepared"
    print_ticket
}

command="$1"
shift
if [[ "$command" != setup && "$command" != request && $# -ne 0 ]]; then
    die "Unexpected arguments for $command."
fi
case "$command" in
    setup) setup "$@" ;;
    cleanup) cleanup_namespace ;;
    request)
        require_prepared
        [[ $# -le 1 ]] || die "Usage: bash request.sh [control]"
        case "${1:-report}" in
            report) query report-app ;;
            control) query test-client ;;
            *) die "Usage: bash request.sh [control]" ;;
        esac
        ;;
    validate) require_prepared; validate ;;
    solution)
        require_prepared
        kn apply -f "$LAB_DIR/manifests/policy.yaml"
        DB_IP="$(service_ip)" || die "Cannot determine report-db Service IP."
        retry 10 2 ready_network || die "Reference repair did not converge."
        validate
        ;;
    *) die "Unknown command." ;;
esac
