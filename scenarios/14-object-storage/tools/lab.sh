#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-14
OWNER=object-storage-14
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 14 · Imports no longer reach storage
Namespace kappa-practice-14

The file importer sends sample CSVs to file-store:8333. Normally it can
upload a file and read the same bytes back from its configured bucket.

Storage is running, but uploads started failing after an importer update.
Restore the original bucket path. Keep the stored files and authentication.

Run bash request.sh from this folder to try an upload inside file-importer.
Use bash validate.sh after the fix. Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

importer() {
    timeout 25s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=20s \
        exec deployment/file-importer -- python /app/importer.py "$@"
}

change_bucket() {
    kn patch configmap importer-settings --type=merge -p "{\"data\":{\"bucket\":\"$1\"}}"
    kn rollout restart deployment/file-importer
    rollout file-importer
}

setup() {
    local marker result rc=0
    create_namespace "$@"
    kn create configmap importer-code --from-file="importer.py=$LAB_DIR/app/importer.py" --dry-run=client -o yaml | kn apply -f -
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout file-store
    rollout file-importer || die "The importer did not start. Check image pulls and PyPI access."
    marker="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    retry 10 2 importer seed "$marker" || die "Could not seed the approved bucket."
    importer validate "$marker" || die "The authenticated baseline did not pass."
    change_bucket field-imports-retired
    result="$(importer probe 2>&1)" || rc=$?
    [[ "$rc" -eq 1 && "$result" == *NoSuchBucket* ]] || die "The expected missing-bucket error did not appear: $result"
    printf '%s\n' "$marker" > "$STATE_DIR/prepared"
    ticket
}

validate() { importer validate "$(cat "$STATE_DIR/prepared")"; }
solution() { change_bucket field-imports; validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; importer probe ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Read the S3 response from bash request.sh. Did the request reach storage?\n' ;;
            2) printf 'Find the bucket named by the importer and compare it with the bucket provisioned for this lab.\n' ;;
            3) printf 'Set bucket to field-imports in importer-settings, then restart the importer.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
