#!/usr/bin/env bash
# Shared scope and readiness helpers. A scenario sets LAB_DIR, LAB_NS, and OWNER.
STATE_DIR="$LAB_DIR/.state"
OWNER_LABEL=training.example.com/scenario

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

connect() {
    [[ "$(uname -s)" == Linux ]] || die "Use the Linux Kubernetes playground."
    for tool in kubectl timeout; do
        command -v "$tool" >/dev/null || die "Missing $tool."
    done
    [[ ! -L "$STATE_DIR" ]] || die "Refusing a symlinked .state directory."
    CONTEXT="$(kubectl config current-context)" || die "Cannot read current context."
    [[ -n "$CONTEXT" ]] || die "Select a Kubernetes context first."
    if [[ -f "$STATE_DIR/context" ]]; then
        [[ "$(cat "$STATE_DIR/context")" == "$CONTEXT" ]] || die "Select the saved lab context."
    fi
}

k() { kubectl --context="$CONTEXT" --request-timeout=20s "$@"; }
kn() { k --namespace="$LAB_NS" "$@"; }

namespace_exists() {
    local result
    result="$(k get namespace "$LAB_NS" --ignore-not-found -o name)" || die "Cannot inspect lab namespace."
    [[ -n "$result" ]]
}

owned() {
    local owner uid
    [[ -f "$STATE_DIR/context" && -s "$STATE_DIR/uid" ]] || die "Saved namespace identity is missing."
    owner="$(k get namespace "$LAB_NS" -o 'jsonpath={.metadata.labels.training\.example\.com/scenario}')" || die "Cannot inspect namespace ownership."
    uid="$(k get namespace "$LAB_NS" -o 'jsonpath={.metadata.uid}')" || die "Cannot inspect namespace identity."
    [[ "$owner" == "$OWNER" && "$uid" == "$(cat "$STATE_DIR/uid")" ]] || die "Namespace ownership or identity differs. Refusing to modify it."
}

create_namespace() {
    [[ $# -eq 0 || ( $# -eq 1 && "${1:-}" == --reset ) ]] || die "Usage: bash setup.sh [--reset]"
    if namespace_exists || [[ -e "$STATE_DIR" ]]; then
        [[ "${1:-}" == --reset ]] || die "Lab already exists. Resume it or use setup.sh --reset to discard this scenario."
        cleanup_namespace
    fi
    local uid
    uid="$(cat <<EOF | k create -f - -o 'jsonpath={.metadata.uid}'
apiVersion: v1
kind: Namespace
metadata:
  name: $LAB_NS
  labels:
    $OWNER_LABEL: $OWNER
EOF
)" || die "Could not create the lab namespace."
    [[ -n "$uid" ]] || die "Namespace creation returned no identity."
    mkdir -p -- "$STATE_DIR"
    printf '%s\n' "$CONTEXT" > "$STATE_DIR/context"
    printf '%s\n' "$uid" > "$STATE_DIR/uid"
}

cleanup_namespace() {
    if namespace_exists; then
        owned
        k delete namespace "$LAB_NS" --wait=true --timeout=120s --request-timeout=0 || die "Lab namespace cleanup did not finish."
    fi
    # The path is fixed beneath the scenario directory and its symlink status was checked.
    rm -f -- "$STATE_DIR/context" "$STATE_DIR/uid" "$STATE_DIR/prepared"
    if [[ -d "$STATE_DIR" ]]; then
        rmdir -- "$STATE_DIR" || die "The local state folder contains other files. Review them before retrying."
    fi
}

require_prepared() {
    owned
    [[ -f "$STATE_DIR/prepared" ]] || die "Setup did not finish. Check its output before attempting the exercise."
}

retry() {
    local tries="$1" pause="$2" i
    shift 2
    for ((i=1; i<=tries; i++)); do
        if "$@"; then return 0; fi
        if (( i < tries )); then sleep "$pause"; fi
    done
    return 1
}

rollout() {
    kn rollout status "deployment/$1" --timeout=240s --request-timeout=0
}
