#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-11
OWNER=mongodb-configuration-11
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 11 · Saved workspace settings are missing
Namespace kappa-practice-11

Operators use workspace-portal to read settings from document-db:27017.
The North Field workspace should show its saved pressure units, bar.

MongoDB is Ready and the portal can log in. After a portal update, the
lookup comes back empty. Restore the original settings through the portal.
Keep MongoDB running and keep the existing workspace data.

Run bash request.sh to check from inside workspace-portal.
Use bash validate.sh after the fix. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

admin() {
    kn exec deployment/document-db -- sh -c '
        exec mongosh "mongodb://127.0.0.1:27017/admin?serverSelectionTimeoutMS=3000" --quiet --norc             --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --eval "$1"
    ' lab "$1"
}

portal() {
    timeout 18s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=15s \
        exec deployment/workspace-portal -- sh -c '
        exec mongosh "mongodb://document-db:27017/$APP_DB?authSource=admin&serverSelectionTimeoutMS=3000" --quiet --norc             --username workspace_app --password "$APP_PASSWORD" --eval "$1"
    ' lab "$1"
}

request() {
    portal 'const row = db.settings.findOne({_id: "north-field"});
            print(row === null ? "EMPTY" : [row.name, row.units, row.marker].join("|"));'
}

has_record() {
    local data
    data="$(request 2>&1)" && [[ "$data" == "North Field|bar|$1" ]]
}

change_database() {
    kn patch configmap portal-settings --type=merge -p "{\"data\":{\"database\":\"$1\"}}"
    kn rollout restart deployment/workspace-portal
    rollout workspace-portal
}

setup() {
    local marker actual
    create_namespace "$@"
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout document-db || die "MongoDB did not start. Check image pull, CPU compatibility, and available memory. No fault injected."
    rollout workspace-portal
    marker="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    admin "db.createUser({user:'workspace_app',pwd:'kappa11-demo-app',
        roles:[{role:'readWrite',db:'workspaces'},{role:'read',db:'workspaces-archive'}]});
        db.getSiblingDB('workspaces').settings.insertOne({_id:'north-field', name:'North Field', units:'bar', marker:'$marker'});"
    retry 10 2 has_record "$marker" || die "The portal could not read the baseline record."
    change_database workspaces-archive
    actual="$(request)" || die "Expected a successful but empty lookup."
    [[ "$actual" == EMPTY ]] || die "The expected empty lookup was not reproduced."
    printf '%s\n' "$marker" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local record write_id observed
    record="$(cat "$STATE_DIR/prepared")"
    has_record "$record" ||
        { printf 'FAIL: The portal did not return the original workspace.\n'; return 1; }
    write_id="check-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    portal "const result = db.settings.insertOne({_id:'$write_id', note:'lab check'});
            if (!result.acknowledged) quit(1);" >/dev/null || return 1
    # Run the read in a new application process, then remove only the test document.
    observed="$(portal "print(db.settings.countDocuments({_id:'$write_id'}));")" || observed=""
    portal "db.settings.deleteOne({_id:'$write_id'});" >/dev/null || return 1
    [[ "$observed" == 1 ]] || { printf 'FAIL: The test write did not survive reconnecting.\n'; return 1; }
    printf 'PASS: The portal reads the original settings, and an authorised write survives reconnecting.\n'
}

solution() { change_database workspaces; validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request|validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Run bash request.sh. Does the login fail, or does the lookup return EMPTY?\n' ;;
            2) printf 'Find the database selected by APP_DB in the portal. Where is that value set?\n' ;;
            3) printf 'Set database to workspaces in portal-settings, then restart the portal Deployment.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
