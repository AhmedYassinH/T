#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-17
OWNER=oidc-login-17
source "$LAB_DIR/../lib/practice.sh"
umask 077

ticket() {
    cat <<'TICKET'
Scenario 17 · Users cannot sign in to the report
Namespace kappa-practice-17

The report is behind login-portal:4180. The portal sends users to the
training identity provider at login-idp:5556 and signs them in on return.

After an endpoint change, the provider rejects the login flow. Restore
access for the demo user and keep anonymous requests blocked.

Run bash request.sh to try the whole sign-in from the lab. Use
bash validate.sh to check both access paths.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}
if [[ "${1:-}" == ticket && $# -eq 1 ]]; then ticket; exit; fi
connect

probe() {
    timeout 35s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=30s \
        exec deployment/login-backend -- python /app/probe.py "$1"
}

set_callback() {
    kn patch configmap portal-login-settings --type=merge -p "{\"data\":{\"redirect-url\":\"$1\"}}"
    kn rollout restart deployment/login-portal
    rollout login-portal
}

setup() {
    create_namespace "$@"
    kn create configmap login-demo-code --from-file="report.py=$LAB_DIR/app/report.py" \
        --from-file="probe.py=$LAB_DIR/app/probe.py" --dry-run=client -o yaml | kn apply -f -
    kn apply -f "$LAB_DIR/manifests/workloads.yaml"
    for deploy in login-idp login-backend login-portal; do rollout "$deploy"; done
    retry 5 2 probe healthy || die "The baseline sign-in could not complete."
    set_callback http://login-portal:4180/oauth2/retired-callback
    retry 5 2 probe broken || die "The expected login rejection did not appear."
    touch "$STATE_DIR/prepared"
    ticket
}

validate() { probe healthy; }
solution() { set_callback http://login-portal:4180/oauth2/callback; retry 5 2 validate; }
command="$1"
shift
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; probe healthy ;;
    validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"
        case "${1:-1}" in
            1) printf 'Run bash request.sh. Which component rejects the sign-in?\n' ;;
            2) printf 'Compare the URL the portal sends with the redirect URIs registered in Dex.\n' ;;
            3) printf 'Restore the portal redirect to /oauth2/callback and restart login-portal.\n' ;;
            *) die "Choose hint level 1, 2 or 3." ;;
        esac ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_namespace ;;
    *) die "Unknown command." ;;
esac
