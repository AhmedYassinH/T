#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-09
OWNER=postgres-auth-09
source "$LAB_DIR/../lib/practice.sh"
umask 077
export LC_ALL=C

ticket() {
    cat <<'TICKET'
Scenario 09 · The report can't log in to PostgreSQL
Namespace kappa-practice-09

The reporting job uses readings-app -> readings-db:5432. It should read
the stored 210.5 pressure sample and write a test reading in a transaction.

The report fails after a credential change, though PostgreSQL is Ready.
Restore the report using the approved login in approved-readings-auth.
Keep the database, original sample and Service. Leave the database login
policy and its current password in place.

Run bash request.sh to try the report inside readings-app.
Use bash validate.sh to check recovery. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

db() {
    kn exec deployment/readings-db -- psql -X -q -w -A -t -U postgres -d readings -v ON_ERROR_STOP=1 -c "$1"
}

request() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec deployment/readings-app -- psql -X -q -w -A -t -v ON_ERROR_STOP=1 -c '
BEGIN;
SELECT pressure_bar, marker FROM readings WHERE id = 1;
INSERT INTO readings VALUES (2, 211.1, NULL) RETURNING pressure_bar;
SELECT pressure_bar FROM readings WHERE id = 2;
ROLLBACK;
'
}

has_report() {
    local result
    result="$(request 2>&1)" && [[ "$result" == "210.5|$1"$'\n211.1\n211.1' ]]
}

auth_failure() {
    local result rc=0
    result="$(request 2>&1)" || rc=$?
    [[ "$rc" -eq 2 && "$result" == *'password authentication failed for user "readings_app"'* ]]
}

password_field() {
    kn get secret "$1" -o 'jsonpath={.data.password}'
}

setup() {
    local marker
    create_namespace "$@"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout readings-db
    rollout readings-app
    marker="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    db "CREATE TABLE readings (id integer PRIMARY KEY, pressure_bar numeric(5,1), marker text);
INSERT INTO readings VALUES (1, 210.5, '$marker');
CREATE ROLE readings_app LOGIN PASSWORD 'kappa09-demo-before';
GRANT SELECT, INSERT ON readings TO readings_app;"
    retry 10 2 has_report "$marker" || die "Baseline report did not pass. No incident was injected."
    db "ALTER ROLE readings_app PASSWORD 'kappa09-demo-current';"
    retry 10 2 auth_failure || die "The expected application login failure did not appear."
    [[ "$(db 'SELECT pressure_bar FROM readings WHERE id=1;')" == 210.5 ]] || die "The database lost the sample record."
    printf '%s\n' "$marker" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local app approved ref
    ref="$(kn get deployment readings-app -o 'jsonpath={.spec.template.spec.containers[0].env[?(@.name=="PGPASSWORD")].valueFrom.secretKeyRef.name}|{.spec.template.spec.containers[0].env[?(@.name=="PGPASSWORD")].valueFrom.secretKeyRef.key}')" || return 1
    [[ "$ref" == 'readings-app-auth|password' || "$ref" == 'approved-readings-auth|password' ]] ||
        { printf 'FAIL: Keep the app login sourced from the approved Secret or the original app Secret.\n'; return 1; }
    app="$(password_field "${ref%|*}")" || return 1
    approved="$(password_field approved-readings-auth)" || return 1
    if [[ -z "$app" || "$app" != "$approved" ]]; then
        printf 'FAIL: The application Secret must contain the approved password.\n'
        return 1
    fi
    has_report "$(cat "$STATE_DIR/prepared")" ||
        { printf 'FAIL: The running app could not read the original record and write a test reading.\n'; return 1; }
    [[ "$(db 'SELECT count(*) FROM readings WHERE id=2;')" == 0 ]] ||
        { printf 'FAIL: The test write must leave no extra record.\n'; return 1; }
    printf 'PASS: The application login, original reading, and read/write check all passed.\n'
}

solution() {
    local approved
    approved="$(password_field approved-readings-auth)"
    [[ -n "$approved" ]] || die "The approved credential is missing."
    # Pass the training credential patch via stdin and keep it out of printed output.
    printf '{"data":{"password":"%s"}}\n' "$approved" | kn patch secret readings-app-auth --type=merge --patch-file=/dev/stdin
    kn rollout restart deployment/readings-app
    rollout readings-app
    retry 10 2 validate || die "The reference repair did not restore the report."
}

command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request|validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Run bash request.sh and read the PostgreSQL error. Is the connection getting through?\n' ;;
            2) printf 'Find the Secret that supplies PGPASSWORD. Compare it with the approved login.\n' ;;
            3) printf 'Copy the approved password to readings-app-auth, then restart readings-app so it reads the update.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
