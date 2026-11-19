#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-08
OWNER=stateful-storage-08
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 08 · The well records database won't start
Namespace kappa-practice-08

The records team reads pressure data from records-db:5432. Its PostgreSQL
Pod gets data from a persistent claim. The sample record is 210.5.

After maintenance, the replacement Pod is stuck and the report is down.
Restore records-db-0 using its original data. Keep the existing PVC in place.

Run bash request.sh to check the live record from records-client.
Use bash validate.sh to check that the original claim and record survived.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}

command="$1"
shift
if [[ "$command" == ticket ]]; then
    [[ $# -eq 0 ]] || die "Usage: bash task.sh"
    ticket
    exit
fi
connect
command -v python3 >/dev/null || die "Missing Python 3 on the playground node."

select_class() {
    local name="$1"
    if [[ -z "$name" ]]; then
        name="$(k get storageclass -o json | python3 -c '
import json, sys
classes = [c for c in json.load(sys.stdin)["items"]
           if c["metadata"].get("annotations", {}).get("storageclass.kubernetes.io/is-default-class") == "true"]
if len(classes) == 1:
    print(classes[0]["metadata"]["name"])
')" || die "Could not read StorageClasses."
    fi
    [[ -n "$name" ]] || die "No single default StorageClass. Use a disposable cluster with a dynamic provisioner, then pass --storage-class NAME."
    local info
    info="$(k get storageclass "$name" -o 'jsonpath={.provisioner}|{.reclaimPolicy}')" || die "StorageClass $name was not found."
    [[ "$info" == *'|Delete' && "$info" != kubernetes.io/no-provisioner\|* ]] ||
        die "Choose a dynamic StorageClass with the Delete reclaim policy."
    printf '%s\n' "$name"
}

query() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec pod/records-client -- psql -X -w -A -t -v ON_ERROR_STOP=1 \
        -c 'SELECT pressure_bar, marker FROM saved_readings WHERE id = 1;'
}

matches_record() {
    local result
    result="$(query 2>&1)" && [[ "$result" == "210.5|$1" ]]
}

rollout_db() {
    kn rollout status statefulset/records-db --timeout=180s --request-timeout=0
}

missing_claim() {
    local reason
    reason="$(kn get pod records-db-0 -o 'jsonpath={.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null)" || return 1
    [[ "$reason" == *'persistentvolumeclaim "records-data-old" not found'* ]]
}

set_claim() {
    kn patch statefulset records-db --type=json -p \
        "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName\",\"value\":\"$1\"}]"
}

setup() {
    local class="" storage uid marker
    local -a reset=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --storage-class) [[ $# -ge 2 ]] || die "Provide a StorageClass name."; class="$2"; shift 2 ;;
            --reset) reset+=(--reset); shift ;;
            *) die "Usage: bash setup.sh [--storage-class NAME] [--reset]" ;;
        esac
    done
    storage="$(select_class "$class")" || exit 2
    create_namespace "${reset[@]}"
    cat <<EOF | kn create -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: records-data
spec:
  storageClassName: $storage
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 128Mi
EOF
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    rollout_db || die "The database did not start. Check PVC events and the storage provisioner. No fault was injected."
    kn wait --for=condition=Ready pod/records-client --timeout=180s --request-timeout=0
    marker="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    kn exec records-db-0 -- psql -U postgres -d wells -X -w -v ON_ERROR_STOP=1 \
        -c "CREATE TABLE saved_readings (id integer PRIMARY KEY, pressure_bar numeric(5,1), marker text); INSERT INTO saved_readings VALUES (1,210.5,'$marker');"
    retry 10 2 matches_record "$marker" || die "Could not verify the baseline record through the Service."
    uid="$(kn get pvc records-data -o 'jsonpath={.metadata.uid}')"
    [[ -n "$uid" ]] || die "Cannot record the claim identity."
    set_claim records-data-old
    retry 30 2 missing_claim || die "The expected claim mount failure did not appear."
    if query >/dev/null 2>&1; then die "The report still works. Setup is incomplete."; fi
    printf '%s|%s\n' "$uid" "$marker" > "$STATE_DIR/prepared"
    ticket
}

validate() {
    local saved_uid marker spec
    IFS='|' read -r saved_uid marker < "$STATE_DIR/prepared"
    spec="$(kn get pvc records-data -o 'jsonpath={.metadata.uid}|{.status.phase}')"
    [[ "$spec" == "$saved_uid|Bound" ]] || { printf 'FAIL: The original PVC must remain bound.\n'; return 1; }
    spec="$(kn get pod records-db-0 -o 'jsonpath={.spec.volumes[?(@.name=="records")].persistentVolumeClaim.claimName}|{.status.conditions[?(@.type=="Ready")].status}')"
    [[ "$spec" == 'records-data|True' ]] || { printf 'FAIL: Use the original claim from the Ready database Pod.\n'; return 1; }
    matches_record "$marker" || { printf 'FAIL: The original sample record did not come back through the Service.\n'; return 1; }
    printf 'PASS: Original PVC and seeded record survived.\n'
}

solution() {
    set_claim records-data
    # After reverting a StatefulSet update, a failed ordinal can require replacement.
    if missing_claim; then kn delete pod records-db-0 --wait=true --timeout=60s; fi
    rollout_db
    retry 10 2 validate || die "Reference repair did not give the original record back."
}

case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; query ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint)
        [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Describe records-db-0 and read the Events at the bottom.\n' ;;
            2) printf 'Compare the PVC named in the Pod template with the claims in this namespace.\n' ;;
            3) printf 'Point the StatefulSet back to records-data. If the bad Pod stays Pending, delete just that Pod.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
