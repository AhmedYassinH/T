#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
[[ $# -eq 0 ]] || die "Usage: bash solution.sh"
require_tools
load_context
require_lab_state

printf 'REFERENCE SOLUTION: repairing the API Service target port.\n'
kn patch service portal-api --type=json \
    -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
printf 'Waiting for Service routing and EndpointSlice convergence...\n'
if ! retry 10 2 bash "$LAB_DIR/validate.sh"; then
    die "Reference repair was applied, but validation still fails. Read the failed checks; extra changes may need investigation."
fi
if [[ -f "$LAB_DIR/SOLUTION.md" ]]; then
    printf '\nRead SOLUTION.md for the investigation and incident explanation.\n'
fi
