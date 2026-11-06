#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_tools
load_context
require_lab_state
if [[ $# -eq 0 ]]; then
    set -- http://portal-gateway/api/status
fi
http_check "$@"
