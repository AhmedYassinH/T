#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-15
OWNER=monitoring-gap-15
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 15 · The dashboard is green but reports fail
Namespace kappa-practice-15

Users submit jobs through report-processor:8080. It calls report-calculator
and normally returns total 36. Prometheus feeds the Reports health panel.

After a configuration change, jobs fail and the panel still says UP.
Restore jobs and explain why the panel missed the impact. Keep monitoring on.

Run bash request.sh to try a job. Use bash request.sh metrics to see the
signals from Prometheus, then bash validate.sh to check recovery.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect

observe() {
    timeout 14s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=12s \
        exec deployment/report-processor -- python -c '
import base64, json, sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

mode = sys.argv[1]
if mode in ("job", "ok", "failed"):
    try:
        response = urlopen("http://report-processor:8080/api/job", timeout=4)
    except HTTPError as error:
        response = error
    with response:
        body = json.load(response)
        print(json.dumps(body))
        if mode == "failed":
            sys.exit(response.code != 502 or body.get("status") != "failed" or not body.get("job"))
        sys.exit(response.code != 200 or body.get("total") != 36 or not body.get("job"))

if mode == "dashboard":
    auth = base64.b64encode(b"admin:kappa15-demo-only").decode()
    req = Request("http://lab-grafana:3000/api/dashboards/uid/report-health",
                  headers={"Authorization": "Basic " + auth})
    with urlopen(req, timeout=3) as response:
        dash = json.load(response)["dashboard"]
    sys.exit(dash["panels"][0]["targets"][0]["expr"] != "up{job=\"report-processor\"}")

def metric(query):
    url = "http://lab-prometheus:9090/api/v1/query?" + urlencode({"query": query})
    with urlopen(url, timeout=3) as response:
        vector = json.load(response)["data"]["result"]
    return float(vector[0]["value"][1]) if vector else None

up = metric("up{job=\"report-processor\"}")
outcome = "failed" if mode == "metrics" or mode == "visible" else "ok"
count = metric("training_jobs_total{outcome=\"" + outcome + "\"}")
print(f"Scrape up = {up}. Reports {outcome} = {count}.")
sys.exit(up != 1 or (mode != "metrics" and (count is None or count < 1)))
' "$@"
}

set_path() {
    kn patch configmap processor-settings --type=merge -p "{\"data\":{\"calculator-path\":\"$1\"}}"
    kn rollout restart deployment/report-processor
    rollout report-processor
}

setup() {
    create_namespace "$@"
    kn create configmap job-metrics-demo --from-file="api.py=$LAB_DIR/app/api.py" --dry-run=client -o yaml | kn apply -f -
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    for deploy in report-calculator report-processor lab-prometheus lab-grafana; do rollout "$deploy"; done
    retry 10 2 observe ok || die "The baseline job failed."
    retry 10 2 observe success || die "Prometheus did not see the baseline job."
    retry 10 2 observe dashboard || die "Grafana did not load the demo dashboard."
    set_path /api/total-v2
    observe failed || die "The intended job error did not appear."
    retry 10 2 observe visible || die "The mismatch between scrape health and failed jobs did not appear."
    touch "$STATE_DIR/prepared"
    ticket
}

validate() {
    observe ok || return 1
    retry 10 2 observe success || return 1
    printf 'PASS: Reports complete and Prometheus sees the successful requests.\n'
}
solution() { set_path /api/total; validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -le 1 ]] || die "Usage: bash request.sh [metrics]"; require_prepared
        case "${1:-job}" in job|metrics) observe "${1:-job}" ;; *) die "Choose metrics or omit the argument." ;; esac ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Compare bash request.sh with bash request.sh metrics. What does up actually measure?\n' ;;
            2) printf 'Look up the failed job ID in the processor logs. Which upstream URL did it call?\n' ;;
            3) printf 'Set calculator-path to /api/total in processor-settings, then restart the processor.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
