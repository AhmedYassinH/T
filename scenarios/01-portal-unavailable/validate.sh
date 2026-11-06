#!/usr/bin/env bash
# GETs and diagnostic exec only: this script does not repair/redeploy anything.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
[[ $# -eq 0 ]] || die "Usage: bash validate.sh"
require_tools
load_context
require_lab_state

snapshot="$(mktemp)"
check_log="$(mktemp)"
trap 'rm -f -- "$snapshot" "$check_log"' EXIT
kn get deployments,services,pods,configmaps,endpointslices -o json > "$snapshot" \
    || die "Cannot collect the lab snapshot. Check API connectivity and permissions."
state_rc=0
python3 "$LAB_DIR/tools/check_state.py" "$snapshot" "$LAB_DIR" > "$check_log" 2>&1 || state_rc=$?
if (( state_rc > 1 )); then cat "$check_log" >&2; die "Could not inspect the snapshot."; fi

passed=0
failed=0
check() {
    local description="$1"
    shift
    if "$@" > "$check_log" 2>&1; then
        printf 'PASS: %s\n' "$description"
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n' "$description"
        cat "$check_log"
        failed=$((failed + 1))
    fi
}

printf 'Scenario 01 recovery validation (%s)\n' "$LAB_NS"
check 'Required workloads, Services, endpoints, probes, and source configuration' \
    python3 "$LAB_DIR/tools/check_state.py" "$snapshot" "$LAB_DIR"

mapfile -t backend_rows < <(python3 "$LAB_DIR/tools/check_state.py" "$snapshot" "$LAB_DIR" --backends)
allowed_backends=""
for row in "${backend_rows[@]}"; do
    name="${row%%|*}"
    allowed_backends+="${allowed_backends:+,}$name"
done

check 'The API Service serves a live application response' \
    http_check http://portal-api/api/status --mode api --allowed-backends "$allowed_backends"
for row in "${backend_rows[@]}"; do
    name="${row%%|*}"
    address="${row#*|}"
    if [[ -z "$address" ]]; then
        printf 'FAIL: %s has no pod address\n' "$name"
        failed=$((failed + 1))
        continue
    fi
    if [[ "$address" == *:* ]]; then address="[$address]"; fi
    check "Backend $name answers directly on its application port" \
        http_check "http://$address:8080/api/status" --mode api --allowed-backends "$name"
done

check 'Sample measurements are returned through the gateway' \
    http_check http://portal-gateway/api/measurements --mode measurements \
    --via-gateway --allowed-backends "$allowed_backends"
check 'Unknown API paths still return 404 through the gateway' \
    http_check http://portal-gateway/api/does-not-exist --mode status --expect-code 404 --via-gateway

repeated_gateway_requests() {
    local attempt
    for ((attempt=1; attempt<=5; attempt++)); do
        http_check http://portal-gateway/api/status --mode api \
            --via-gateway --allowed-backends "$allowed_backends" || return 1
    done
}
check 'Five fresh requests succeed through the intended gateway route' repeated_gateway_requests
printf '\nResults: %s check groups passed, %s failed.\n' "$passed" "$failed"
if (( failed > 0 )); then
    printf 'Recovery is incomplete. No repairs were applied by this validator.\n'
    exit 1
fi
printf 'Recovery checks passed. Complete the short incident handover in TASK.md.\n'
