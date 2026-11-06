#!/usr/bin/env bash
# Shared helpers. Source this file; do not run it as an exercise.

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$LAB_DIR/.state"
LAB_NS="kappa-practice-01"
OWNER_LABEL="training.example.com/scenario"
OWNER_VALUE="kappa-devops-practice-01"
LAB_CONTEXT=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

require_tools() {
    local tool
    for tool in bash kubectl python3 timeout; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing $tool. Use a Linux Killercoda Kubernetes playground. See README.md."
    done
}

load_context() {
    local current
    current="$(kubectl config current-context)" || die "Cannot read the current Kubernetes context."
    [[ -n "$current" ]] || die "No Kubernetes context selected."
    LAB_CONTEXT="$current"
    if [[ -f "$STATE_DIR/context" ]]; then
        IFS= read -r LAB_CONTEXT < "$STATE_DIR/context" || die "Cannot read saved context."
        [[ "$LAB_CONTEXT" == "$current" ]] || die "Current context differs from this lab's saved context ($LAB_CONTEXT). Select that context or use a fresh playground/copy."
    fi
}

k() { kubectl --context="$LAB_CONTEXT" --request-timeout=20s "$@"; }
kn() { k --namespace="$LAB_NS" "$@"; }

assert_owned_namespace() {
    local owner actual_uid saved_uid
    owner="$(k get namespace "$LAB_NS" -o 'jsonpath={.metadata.labels.training\.example\.com/scenario}')" || die "Lab namespace is unavailable. Run setup.sh first."
    [[ "$owner" == "$OWNER_VALUE" ]] || die "Namespace $LAB_NS is not marked as this lab. Refusing to modify or remove it."
    if [[ -f "$STATE_DIR/namespace-uid" ]]; then
        IFS= read -r saved_uid < "$STATE_DIR/namespace-uid" || die "Cannot read saved namespace identity."
        actual_uid="$(k get namespace "$LAB_NS" -o 'jsonpath={.metadata.uid}')" || die "Cannot read namespace identity."
        [[ -n "$saved_uid" && "$saved_uid" == "$actual_uid" ]] || die "Namespace identity changed. Use a fresh playground/copy rather than deleting an unfamiliar replacement."
    fi
}

require_lab_state() {
    [[ -f "$STATE_DIR/context" && -f "$STATE_DIR/namespace-uid" ]] || die "Lab state is missing. Run setup.sh first from this copy of the lab."
    assert_owned_namespace
}

http_check() {
    # Executes only a read-only HTTP client in the existing diagnostic pod.
    timeout 20s kubectl --context="$LAB_CONTEXT" --request-timeout=15s \
        --namespace="$LAB_NS" exec -i pod/lab-client -- \
        python - "$@" < "$LAB_DIR/tools/http_check.py"
}

retry() {
    local attempts="$1" pause="$2" attempt
    shift 2
    for ((attempt=1; attempt<=attempts; attempt++)); do
        if "$@"; then return 0; fi
        if (( attempt < attempts )); then sleep "$pause"; fi
    done
    return 1
}

diagnostics() {
    printf '\nDiagnostic snapshot for %s:\n' "$LAB_NS" >&2
    kn get pods,deployments,services,endpointslices -o wide >&2 || true
    kn get events --sort-by=.metadata.creationTimestamp >&2 || true
    printf 'Setup stopped. Read the error above; do not treat a partial setup as a practice incident.\n' >&2
}
