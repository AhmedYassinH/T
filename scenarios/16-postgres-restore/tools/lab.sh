#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-16
OWNER=postgres-restore-16
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 16 · Prove the backup can be restored
Namespace kappa-practice-16

The reports team needs yesterday's dataset in recovery-db:5432. The SQL
backup is the snapshot.sql key in ConfigMap pressure-backup. The target
database is reports. The live source-db has a newer record.

Restore the snapshot into recovery-db. Leave source-db alone. The recovery
copy should contain the original sample and exclude the later record.

Run bash request.sh to check the recovery database from reports-client.
Use bash request.sh source to compare it with live data.
Use bash validate.sh after restoring. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

source_sql() {
    kn exec deployment/source-db -- psql -X -q -w -A -t -v ON_ERROR_STOP=1 -U postgres -d reports -c "$1"
}

read_dataset() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec pod/reports-client -- psql -X -q -w -A -t -v ON_ERROR_STOP=1 -h "$1" -U postgres -d reports \
        -c 'SELECT id, pressure_bar, marker FROM well_reports ORDER BY id;'
}

target_empty() {
    local result
    result="$(kn exec deployment/recovery-db -- psql -X -q -w -A -t -v ON_ERROR_STOP=1 -U postgres -d reports \
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='well_reports';")"
    [[ "$result" == 0 ]]
}

setup() {
    local id snapshot
    create_namespace "$@"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout source-db
    rollout recovery-db
    kn wait --for=condition=Ready pod/reports-client --timeout=180s --request-timeout=0
    id="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    source_sql "CREATE TABLE well_reports (id integer PRIMARY KEY, pressure_bar numeric(5,1), marker text);
INSERT INTO well_reports VALUES (1,210.5,'$id');"
    snapshot="$(kn exec deployment/source-db -- pg_dump -U postgres -d reports --no-owner --no-privileges)" ||
        die "Could not capture the backup."
    [[ "$snapshot" == *'PostgreSQL database dump complete'* && "$snapshot" == *"$id"* ]] ||
        die "The archive is missing data or the completion marker."
    printf '%s\n' "$snapshot" | kn create configmap pressure-backup --from-file=snapshot.sql=/dev/stdin
    source_sql "INSERT INTO well_reports VALUES (2,211.1,'after-$id');"
    target_empty || die "Recovery target already contains restored data."
    [[ "$(read_dataset source-db)" == "1|210.5|$id"$'\n'"2|211.1|after-$id" ]] ||
        die "Could not verify the live source baseline."
    printf '%s\n' "$id" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local id target source
    id="$(cat "$STATE_DIR/prepared")"
    target="$(read_dataset recovery-db)" || { printf 'FAIL: Recovery target is still missing the report table.\n'; return 1; }
    source="$(read_dataset source-db)" || return 1
    [[ "$target" == "1|210.5|$id" ]] ||
        { printf 'FAIL: Recovery must contain exactly the original sample.\n'; return 1; }
    [[ "$source" == "1|210.5|$id"$'\n'"2|211.1|after-$id" ]] ||
        { printf 'FAIL: Source data changed.\n'; return 1; }
    printf 'PASS: Snapshot matches its recovery point. The source retains its newer record.\n'
}

solution() {
    target_empty || die "The target already has a report table. Inspect it before restoring again."
    kn get configmap pressure-backup -o 'jsonpath={.data.snapshot\.sql}' | \
        kn exec -i deployment/recovery-db -- psql -X -v ON_ERROR_STOP=1 --single-transaction -U postgres -d reports -f -
    validate
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -le 1 ]] || die "Usage: bash request.sh [source]"; require_prepared
        case "${1:-recovery}" in source|recovery) read_dataset "${1:-recovery}-db" ;; *) die "Choose source or recovery." ;; esac ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Compare the source and recovery results. Which database should receive changes?\n' ;;
            2) printf 'The ConfigMap holds a plain SQL dump. Which PostgreSQL command reads SQL from stdin?\n' ;;
            3) printf 'Pipe the snapshot.sql key to psql in recovery-db, then check both databases.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
