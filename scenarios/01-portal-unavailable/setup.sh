#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[[ $# -eq 0 || ( $# -eq 1 && "${1:-}" == "--reset" ) ]] || die "Usage: bash setup.sh [--reset]"
require_tools
load_context
k get nodes >/dev/null || die "Cannot access a Kubernetes cluster. Open the Killercoda Kubernetes playground."
ready_nodes="$(k get nodes -o 'jsonpath={range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}')"
[[ "$ready_nodes" == *True* ]] || die "No Ready node found. Wait for the playground to finish starting."
for operation in 'create namespaces' 'create deployments.apps' 'create services' 'create configmaps' 'create pods' 'create pods/exec' 'patch services' 'list endpointslices.discovery.k8s.io'; do
    read -r verb resource <<< "$operation"
    if [[ "$resource" == "namespaces" ]]; then
        permission="$(k auth can-i "$verb" "$resource")" || die "Cluster permissions unavailable."
    else
        permission="$(kn auth can-i "$verb" "$resource")" || die "Namespace permissions unavailable."
    fi
    [[ "$permission" == "yes" ]] || die "This exercise needs '$operation' permission in its playground."
done

existing="$(k get namespace "$LAB_NS" --ignore-not-found -o name)" || die "Cannot check namespace availability."
if [[ -n "$existing" ]]; then
    assert_owned_namespace
    [[ "${1:-}" == "--reset" ]] || die "Lab already exists. Resume it, or use 'bash setup.sh --reset' to discard and recreate only this lab."
    bash "$LAB_DIR/cleanup.sh"
fi

printf 'Preparing scenario 01 in context %s, namespace %s.\n' "$LAB_CONTEXT" "$LAB_NS"
mkdir -p "$STATE_DIR"
k create -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $LAB_NS
  labels:
    $OWNER_LABEL: $OWNER_VALUE
EOF
printf '%s\n' "$LAB_CONTEXT" > "$STATE_DIR/context"
k get namespace "$LAB_NS" -o 'jsonpath={.metadata.uid}' > "$STATE_DIR/namespace-uid"
printf '\n' >> "$STATE_DIR/namespace-uid"
trap 'diagnostics' ERR

kn create configmap portal-api-code --from-file="app.py=$LAB_DIR/app/app.py" \
    --dry-run=client -o yaml | kn apply -f - >/dev/null
kn create configmap portal-gateway-config --from-file="nginx.conf=$LAB_DIR/manifests/gateway.conf" \
    --dry-run=client -o yaml | kn apply -f - >/dev/null
kn apply -f "$LAB_DIR/manifests/workloads.yaml" >/dev/null
service_family="$(kn get service portal-api -o 'jsonpath={.spec.ipFamilies[0]}')"
[[ "$service_family" == "IPv4" ]] || die "This lab targets the standard IPv4 playground. An IPv6-primary Service needs a different API listener configuration."
printf 'Waiting for the small lab workloads and image pulls...\n'
kn rollout status deployment/portal-api --timeout=240s --request-timeout=0
kn rollout status deployment/portal-gateway --timeout=240s --request-timeout=0
kn wait --for=condition=Ready pod/lab-client --timeout=240s --request-timeout=0

printf 'Checking the working baseline...\n'
if ! retry 10 2 bash "$LAB_DIR/validate.sh" > "$STATE_DIR/baseline-validation.log" 2>&1; then
    cat "$STATE_DIR/baseline-validation.log" >&2
    die "The healthy baseline did not pass. This is a setup/environment problem; no incident was injected."
fi

# Authoring detail / spoiler: direct pod probes stay healthy while Service routing fails.
kn patch service portal-api --type=json \
    -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":8081}]' >/dev/null
if ! retry 15 2 http_check http://portal-gateway/api/status \
    --mode status --expect-code 502 --via-gateway > "$STATE_DIR/incident-http.log" 2>&1; then
    cat "$STATE_DIR/incident-http.log" >&2
    die "The intended incident was not reproduced. Do not start the exercise from this partial setup."
fi

broken_rc=0
bash "$LAB_DIR/validate.sh" > "$STATE_DIR/broken-validation.log" 2>&1 || broken_rc=$?
[[ "$broken_rc" -eq 1 ]] || die "Expected a failed recovery validation (exit 1), got $broken_rc. Inspect .state/broken-validation.log."
printf 'ready\n' > "$STATE_DIR/prepared"
trap - ERR
printf '\nScenario ready. The portal incident has been reproduced.\n'
printf 'The recovery validator is expected to FAIL until you repair the issue.\n\n'
if [[ -f "$LAB_DIR/TASK.md" ]]; then
    cat "$LAB_DIR/TASK.md"
else
    cat <<'TICKET'
Support ticket 01: The portal returns gateway errors after configuration maintenance.
Investigate namespace kappa-practice-01 and restore the client-to-API request path.
Keep the existing gateway, API configuration, health probes, and replica counts.
Both API replicas must remain healthy; status and measurement requests must work
through the gateway. Do not bypass the gateway or hard-code pod addresses.

Reproduce: bash request.sh
Validate:  bash validate.sh
Reference repair if stuck: bash solution.sh
TICKET
fi
