#!/usr/bin/env bash
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_NS=kappa-practice-20
OWNER=terraform-deployment-20
source "$LAB_DIR/../lib/practice.sh"
umask 077
WORK="$STATE_DIR/work"
INPUTS="$WORK/ka.auto.tfvars.json"
if [[ "${1:-}" == cases && $# -eq 1 ]]; then printf 'context\npvc\ndrift\n'; exit; fi

connect

tf() { TF_IN_AUTOMATION=1 terraform -chdir="$WORK" "$@"; }

ticket() {
    printf '\nScenario 20 · A Terraform change needs review\nNamespace %s\n\n' "$LAB_NS"
    printf 'Terraform manages report-stack:80. The report serves its release at /release and its operating mode at /mode.\n\n'
    case "$(cut -d'|' -f1 "$STATE_DIR/prepared")" in
        context) printf 'kubectl connects, but Terraform cannot plan. Fix the cluster input and deploy release v1 in this namespace.\n' ;;
        pvc) printf 'Release v2 is approved. The proposed plan also replaces storage. Revise the plan and ship v2 with the original claim and data.\n' ;;
        drift) printf 'The app is running an approved operational fix. Update Terraform so its next plan preserves that live setting.\n' ;;
    esac
    cat <<'TICKET'

Inputs are in .state/work/ka.auto.tfvars.json. Run bash request.sh to
review the plan. Terraform commands use terraform -chdir=.state/work.
Use bash validate.sh to check the live Service and plan.
Stuck? Try bash hint.sh 1, then 2 or 3.
TICKET
}

case_name() { case "$1" in context|pvc|drift) ;; *) die "Choose context, pvc or drift." ;; esac; }

set_inputs() {
    python3 - "$INPUTS" "$@" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text()) if path.exists() else {}
for arg in sys.argv[2:]:
    name, value = arg.split("=", 1)
    data[name] = value
path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

select_class() {
    local name="${LAB_STORAGE_CLASS:-}" info
    if [[ -z "$name" ]]; then
        name="$(k get storageclass -o json | python3 -c '
import json, sys
matches = [c for c in json.load(sys.stdin)["items"]
           if c["metadata"].get("annotations", {}).get("storageclass.kubernetes.io/is-default-class") == "true"]
if len(matches) == 1:
    print(matches[0]["metadata"]["name"])
')" || return 1
    fi
    [[ -n "$name" ]] || die "The pvc case needs a working default StorageClass or LAB_STORAGE_CLASS=NAME."
    info="$(k get sc "$name" -o 'jsonpath={.provisioner}|{.reclaimPolicy}')" || return 1
    [[ "$info" == *'|Delete' && "$info" != kubernetes.io/no-provisioner\|* ]] ||
        die "Use a dynamic StorageClass with the Delete reclaim policy."
    printf '%s\n' "$name"
}

portal() {
    timeout 12s kubectl --context="$CONTEXT" --namespace="$LAB_NS" --request-timeout=10s \
        exec deployment/report-stack -- python -c '
import sys
from urllib.request import urlopen
with urlopen("http://report-stack" + sys.argv[1], timeout=4) as response:
    print(response.read().decode().strip())
' "$1"
}

portal_is() {
    local result
    result="$(portal "$1" 2>&1)" && [[ "$result" == "$2" ]]
}

plan_has() {
    local wanted="$1"
    tf show -json candidate.tfplan | python3 -c '
import json, sys
kind = sys.argv[1]
changes = json.load(sys.stdin).get("resource_changes", [])
if kind == "replacement":
    for row in changes:
        if row["type"] == "kubernetes_persistent_volume_claim_v1" and set(row["change"]["actions"]) == {"create", "delete"}:
            sys.exit(0)
elif kind == "revert-mode":
    for row in changes:
        if row["type"] == "kubernetes_config_map_v1":
            change = row["change"]
            if (change["before"]["data"]["mode"], change["after"]["data"]["mode"]) == ("approved-hotfix", "standard"):
                sys.exit(0)
sys.exit(1)
' "$wanted"
}

plan_with_changes() {
    local rc=0
    tf plan -input=false -detailed-exitcode -out=candidate.tfplan || rc=$?
    [[ "$rc" -eq 2 ]] || die "Expected a valid plan with changes. Got code $rc."
    plan_has "$1" || die "The intended plan change did not appear."
}

cleanup_lab() {
    [[ ! -L "$WORK" ]] || die "Refusing a symlinked Terraform work directory."
    if namespace_exists; then owned; fi
    # Only this lab's generated working directory is disposable.
    if [[ -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
    cleanup_namespace
}

setup() {
    local selected=context storage="" marker="" uid="" path result candidates
    if [[ $# -gt 0 && "$1" != --reset ]]; then selected="$1"; shift; fi
    case_name "$selected"
    [[ $# -eq 0 || ( $# -eq 1 && "${1:-}" == --reset ) ]] || die "Usage: bash setup.sh [context|pvc|drift] [--reset]"
    path="${KUBECONFIG:-$HOME/.kube/config}"
    [[ "$path" != *:* && -f "$path" ]] || die "Use a single existing kubeconfig file in KUBECONFIG."
    path="$(realpath "$path")"
    if [[ "$selected" == pvc ]]; then storage="$(select_class)" || exit 2; fi
    if [[ "${1:-}" == --reset ]]; then cleanup_lab; fi
    create_namespace
    mkdir "$WORK"
    cp -- "$LAB_DIR/infra/main.tf" "$WORK/main.tf"
    set_inputs "kube_config_path=$path" "kube_context=$CONTEXT" "storage_class=$storage"
    tf init -input=false
    tf validate

    if [[ "$selected" == context ]]; then
        tf plan -input=false || die "The correct context failed its baseline plan."
        candidates="$(kubectl config get-contexts -o name)" || die "Cannot read kubeconfig contexts."
        if grep -Fxq kappa-demo-retired-context <<< "$candidates"; then die "The demonstration context already exists."; fi
        set_inputs kube_context=kappa-demo-retired-context
        if result="$(tf plan -input=false 2>&1)"; then die "The bad context should prevent Terraform planning."; fi
        case "$result" in
            *kappa-demo-retired-context*|*localhost*|*"no configuration has been provided"*) ;;
            *) die "Expected a kubeconfig context error: $result" ;;
        esac
    else
        tf apply -auto-approve -input=false
        rollout report-stack
        retry 10 2 portal_is /release v1 || die "The baseline release did not respond."
        if [[ "$selected" == pvc ]]; then
            marker="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
            uid="$(kn get pvc report-data -o 'jsonpath={.metadata.uid}')"
            [[ -n "$uid" ]] || die "Could not identify the original claim."
            kn exec deployment/report-stack -- sh -c 'printf "%s\n" "$1" > /data/original-reading' lab "$marker"
            set_inputs release=v2 claim_name=report-data-v2
            plan_with_changes replacement
        else
            kn patch configmap report-release --type=merge -p '{"data":{"mode":"approved-hotfix"}}'
            retry 60 2 portal_is /mode approved-hotfix || die "The live incident fix did not appear through the Service."
            plan_with_changes revert-mode
        fi
        # Discard the intentionally unsafe setup plan so it cannot be applied by accident.
        rm -f -- "$WORK/candidate.tfplan"
    fi
    printf '%s|%s|%s\n' "$selected" "$uid" "$marker" > "$STATE_DIR/prepared"
    ticket
}

clean_plan() {
    local rc=0
    tf plan -input=false -detailed-exitcode || rc=$?
    [[ "$rc" -eq 0 ]] || { printf 'FAIL: Terraform still reports changes or cannot plan.\n'; return 1; }
}

validate() {
    local selected uid marker current
    IFS='|' read -r selected uid marker < "$STATE_DIR/prepared"
    if [[ "$selected" == pvc ]]; then
        current="$(kn get pvc report-data -o 'jsonpath={.metadata.uid}|{.status.phase}')" || return 1
        [[ "$current" == "$uid|Bound" ]] || { printf 'FAIL: The original bound PVC is missing.\n'; return 1; }
        [[ "$(kn exec deployment/report-stack -- cat /data/original-reading)" == "$marker" ]] ||
            { printf 'FAIL: The original data did not survive the release.\n'; return 1; }
        retry 60 2 portal_is /release v2 ||
            { printf 'FAIL: Release v2 is unavailable through the Service.\n'; return 1; }
    elif [[ "$selected" == drift ]]; then
        portal_is /mode approved-hotfix || { printf 'FAIL: The live operating mode must stay approved-hotfix.\n'; return 1; }
    else
        retry 20 2 portal_is /release v1 || { printf 'FAIL: The v1 Service is unavailable.\n'; return 1; }
    fi
    clean_plan || return 1
    printf 'PASS: The live change meets the ticket and the Terraform plan is clean.\n'
}

safe_apply() {
    tf plan -input=false -out=reviewed.tfplan
    tf show -json reviewed.tfplan | python3 -c '
import json, sys
if any("delete" in x["change"]["actions"] for x in json.load(sys.stdin).get("resource_changes", [])):
    sys.exit("Refusing to apply a plan that deletes or replaces resources.")
'
    tf apply -input=false reviewed.tfplan
    rm -f -- "$WORK/reviewed.tfplan"
}

solution() {
    local selected
    selected="$(cut -d'|' -f1 "$STATE_DIR/prepared")"
    case "$selected" in
        context) set_inputs "kube_context=$CONTEXT"; safe_apply ;;
        pvc) set_inputs claim_name=report-data release=v2; safe_apply ;;
        drift) set_inputs mode=approved-hotfix ;;
    esac
    validate
}

hint() {
    local selected
    selected="$(cut -d'|' -f1 "$STATE_DIR/prepared")"
    case "$selected:${1:-1}" in
        context:1) printf 'Read the Terraform error and compare it with kubectl config current-context.\n' ;;
        context:2) printf 'The installer uses its own kube_context input. Compare it with kubectl config get-contexts.\n' ;;
        context:3) printf 'Set kube_context to the working context in ka.auto.tfvars.json, then plan and apply.\n' ;;
        pvc:1) printf 'Review the plan. Which resource would be destroyed?\n' ;;
        pvc:2) printf 'Compare the planned claim name with the bound claim. Does the release actually require renaming it?\n' ;;
        pvc:3) printf 'Keep claim_name as report-data and release as v2. Review the revised plan before applying.\n' ;;
        drift:1) printf 'Read the mode in the live ConfigMap and compare it with the next Terraform plan.\n' ;;
        drift:2) printf 'Find the Terraform input for mode. What value did the team approve on the live app?\n' ;;
        drift:3) printf 'Set mode to approved-hotfix in ka.auto.tfvars.json and check that Terraform now plans no changes.\n' ;;
        *) die "Choose hint level 1, 2 or 3." ;;
    esac
}

command="$1"
shift
case "$command" in
    setup|request|validate|solution)
        for tool in terraform python3; do
            command -v "$tool" >/dev/null || die "Missing $tool. Install it on the disposable playground. Terraform: https://developer.hashicorp.com/terraform/install"
        done ;;
esac
case "$command" in
    setup) setup "$@" ;;
    request) [[ $# -eq 0 ]] || die "Usage: bash request.sh"; require_prepared; tf plan -input=false ;;
    ticket|validate|solution) [[ $# -eq 0 ]] || die "Unexpected arguments."; require_prepared; "$command" ;;
    hint) [[ $# -le 1 ]] || die "Usage: bash hint.sh [1|2|3]"; require_prepared; hint "$@" ;;
    cleanup) [[ $# -eq 0 ]] || die "Usage: bash cleanup.sh"; cleanup_lab ;;
    *) die "Unknown command." ;;
esac
