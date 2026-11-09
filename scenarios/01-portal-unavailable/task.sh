#!/usr/bin/env bash
set -euo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -eq 0 ]] || { printf 'Usage: bash task.sh\n' >&2; exit 2; }
if [[ -f "$LAB_DIR/TASK.md" ]]; then
    cat "$LAB_DIR/TASK.md"
else
    cat <<'TICKET'
Support ticket 01: the automation portal returns gateway errors after maintenance.

SYSTEM AND NORMAL BEHAVIOR
This fictional portal lets operations staff read sample well-pressure measurements.
NGINX is the portal entry point; a small API supplies status and measurement data.
There is no separate browser UI or database in this demonstration.

Namespace: kappa-practice-01. Intended request path:
lab-client -> portal-gateway Service:80 -> NGINX Pod:8080
           -> portal-api Service:80 -> one of two API Pods:8080
The gateway has one replica. Both Services are ClusterIP Services inside the cluster.

GET /api/status should return HTTP 200 with app=energy-automation-demo, status=ok,
and backend_id identifying the API Pod. GET /api/measurements should return three
sample measurements through the same gateway. Unknown API paths should return 404.

CONFIGURATION AND HELPER
Services select Pods and map Service ports to application listening ports.
NGINX configuration comes from portal-gateway-config; API code from portal-api-code.
request.sh executes an HTTP client inside the existing lab-client Pod. Its default
URL is http://portal-gateway/api/status; it prints HTTP status, headers, and body.
It reproduces the client path; it is not an application setting to repair.
Service names resolve inside Pods; node-shell DNS is a different context.
backend_id identifies the responder; nonce is a fresh request ID echoed by the API.

INCIDENT AND ASSIGNMENT
After configuration maintenance, portal requests return gateway errors. The client
reports that Pods and local health checks are green. Follow the request path,
collect evidence, and restore access with the smallest justified change.
Keep gateway/API configuration, source, health probes, Services, and replica counts.
Do not bypass the gateway, hard-code Pod IPs, or change other namespaces.
Recovery requires repeated successful gateway requests and both healthy API replicas.

Reproduce: bash request.sh
Validate: bash validate.sh (expected to fail before recovery; it makes no repairs)
Reference repair if stuck: bash solution.sh
Cleanup when finished: bash cleanup.sh
Handover: impact, evidence, cause, change, recovery proof, and prevention.
All data and applications here are fictional training fixtures.
TICKET
fi
