#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-12
OWNER=cassandra-history-12
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 12 · Historical readings disappeared
Namespace kappa-practice-12

The history reader queries Cassandra through history-db:9042. The sample
reading for well-17 is 210.5. Cassandra is Ready, but the query returns no
rows after a reader configuration update.

Restore the history query using the original data. Keep the database and
its existing keyspaces in place.

Run bash request.sh to query from inside history-client, then use
bash validate.sh to check the original sample and a test write.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

client() {
    timeout 16s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=12s \
        exec deployment/history-client -- sh -c '
        exec cqlsh --no-color --connect-timeout=4 --request-timeout=4 -k "$APP_KEYSPACE" -e "$1" history-db 9042
    ' lab "$1"
}

db() {
    kn exec deployment/history-db -- cqlsh --no-color --connect-timeout=4 --request-timeout=6 -e "$1" 127.0.0.1 9042
}

request() { client "SELECT pressure, marker FROM samples WHERE well_id='well-17';"; }
has_history() {
    local data
    data="$(request 2>&1)" && [[ "$data" == *210.5* && "$data" == *"$1"* ]]
}

change_keyspace() {
    kn patch configmap history-settings --type=merge -p "{\"data\":{\"keyspace\":\"$1\"}}"
    kn rollout restart deployment/history-client
    rollout history-client
}

database_ready() { db 'SELECT release_version FROM system.local;' >/dev/null 2>&1; }

setup() {
    local marker result
    create_namespace "$@"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    printf 'Waiting for Cassandra to start. A fresh 4 GB playground leaves more headroom.\n'
    rollout history-db || die "Cassandra did not become Ready. Check Pod events, memory and startup logs. No incident was injected."
    rollout history-client
    retry 12 3 database_ready || die "Cassandra is listening but CQL did not become usable."
    marker="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    db "CREATE KEYSPACE measurements WITH replication = {'class':'SimpleStrategy','replication_factor':1};
CREATE KEYSPACE maintenance WITH replication = {'class':'SimpleStrategy','replication_factor':1};
CREATE TABLE measurements.samples (well_id text PRIMARY KEY, pressure decimal, marker text);
CREATE TABLE maintenance.samples (well_id text PRIMARY KEY, pressure decimal, marker text);
INSERT INTO measurements.samples (well_id, pressure, marker) VALUES ('well-17',210.5,'$marker');"
    retry 10 2 has_history "$marker" || die "The history reader could not retrieve the seeded record."
    change_keyspace maintenance
    result="$(request)" || die "Expected the query to run against an empty dataset."
    [[ "$result" == *'(0 rows)'* ]] || die "The intended empty query was not reproduced."
    printf '%s\n' "$marker" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local record id observed
    record="$(cat "$STATE_DIR/prepared")"
    has_history "$record" || { printf 'FAIL: The original historical reading is missing.\n'; return 1; }
    id="check-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    client "INSERT INTO samples (well_id, pressure, marker) VALUES ('$id', 211.1, '$id') USING TTL 300;" >/dev/null || return 1
    observed="$(client "SELECT pressure, marker FROM samples WHERE well_id='$id';")" || observed=""
    client "DELETE FROM samples WHERE well_id='$id';" >/dev/null || return 1
    [[ "$observed" == *211.1* && "$observed" == *"$id"* ]] ||
        { printf 'FAIL: Could not read back the test sample.\n'; return 1; }
    printf 'PASS: Original history and a fresh CQL write/read both work.\n'
}

solution() { change_keyspace measurements; validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request|validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Run bash request.sh. Is this a connection error or a query that returned zero rows?\n' ;;
            2) printf 'Check which keyspace history-client selects. Does that keyspace hold the historical readings?\n' ;;
            3) printf 'Set keyspace to measurements in history-settings and roll out new reader Pods.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
