#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
[[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"
require_tools
load_context
existing="$(k get namespace "$LAB_NS" --ignore-not-found -o name)" || die "Cannot check namespace state."
if [[ -n "$existing" ]]; then
    assert_owned_namespace
    printf 'Deleting only the owned lab namespace %s in context %s.\n' "$LAB_NS" "$LAB_CONTEXT"
    k delete namespace "$LAB_NS" --wait=true --timeout=120s --request-timeout=0
else
    printf 'Lab namespace is already absent.\n'
fi
# Remove only known local runtime files; preserve this scenario's sources.
rm -f -- "$STATE_DIR/context" "$STATE_DIR/namespace-uid" "$STATE_DIR/prepared" \
    "$STATE_DIR/baseline-validation.log" "$STATE_DIR/broken-validation.log" "$STATE_DIR/incident-http.log"
printf 'Cleanup complete. Scenario source files were retained.\n'
