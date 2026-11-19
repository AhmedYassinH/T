#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-18
OWNER=external-import-18
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 18 · The source responds but new readings don't arrive
Namespace kappa-practice-18

The importer polls a demo source at demo-source:8080 and writes well-17's
readings to reading-archive. Its connection test succeeds, but a reading
added after a connector update is missing from the archive.

Restore the new reading without losing or duplicating the original.

Run bash request.sh to check the connection and try an import from the
worker Pod. Use bash validate.sh to check the archive after a repeat import.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

importer() {
    timeout 25s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=20s \
        exec deployment/reading-importer -- python /app/import_demo.py "$@"
}

change_well() {
    kn patch configmap connector-settings --type=merge -p "{\"data\":{\"well\":\"$1\"}}"
    kn rollout restart deployment/reading-importer
    rollout reading-importer
}

setup() {
    local id result rc=0
    create_namespace "$@"
    kn create configmap import-demo-code --from-file="import_demo.py=$LAB_DIR/app/import_demo.py" --dry-run=client -o yaml | kn apply -f -
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    for deploy in demo-source reading-archive reading-importer; do rollout "$deploy"; done
    retry 10 2 importer baseline || die "The baseline import did not reach the archive."
    change_well well-71
    id="reading-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    importer seed "$id"
    result="$(importer probe 2>&1)" || rc=$?
    [[ "$rc" -eq 2 && "$result" == *'Found 0 source rows'* ]] ||
        die "Expected a successful connection and empty readings response."
    printf '%s\n' "$id" > "$STATE_DIR/prepared"
    ticket
}

validate() { importer validate "$(cat "$STATE_DIR/prepared")"; }
solution() { change_well well-17; retry 5 2 validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; importer probe ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'What does the connection test prove? Compare it with the number of returned readings.\n' ;;
            2) printf 'Check the well in connector-settings and compare it with the requested well in the ticket.\n' ;;
            3) printf 'Set well to well-17 in connector-settings and restart reading-importer.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
