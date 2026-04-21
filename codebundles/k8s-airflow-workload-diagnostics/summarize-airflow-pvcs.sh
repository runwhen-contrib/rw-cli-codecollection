#!/usr/bin/env bash
# Lists PVCs used by Airflow or matching common volume name patterns; flags non-Bound phases.
set -euo pipefail
set -x

: "${CONTEXT:?}" "${NAMESPACE:?}"

OUTPUT_FILE="${OUTPUT_FILE:-summarize_airflow_pvcs_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"

if ! pvc_json=$("${KUBECTL}" get pvc -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null); then
  echo '[{"title":"Cannot list PVCs","details":"kubectl get pvc failed","severity":4,"next_steps":"Verify RBAC for persistentvolumeclaims in this namespace."}]' | jq . > "$OUTPUT_FILE"
  exit 0
fi

if ! pods_json=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  pods_json='{"items":[]}'
fi

used_claims=$(echo "$pods_json" | jq -r '[.items[]? | .spec.volumes[]? | .persistentVolumeClaim.claimName // empty] | unique | join("|")')

issues_json=$(echo "$pvc_json" | jq \
  --arg used "$used_claims" \
  --arg ns "$NAMESPACE" '
  def claim_in_use($name):
    (($used | split("|")) | map(select(length > 0)) | index($name)) != null;
  def is_airflow_pvc($name):
    claim_in_use($name) or ($name | test("dags|logs|plugins|airflow|git-sync|persistence"; "i"));
  [ .items[]?
    | select(is_airflow_pvc(.metadata.name))
    | (.metadata.name) as $n
    | (.status.phase // "Unknown") as $ph
    | (.spec.resources.requests.storage // "?") as $req
    | select($ph != "Bound")
    | {
        "title": ("PVC `" + $n + "` is " + $ph + " in `" + $ns + "`"),
        "details": ("Phase: " + $ph + ", requested: " + $req),
        "severity": 3,
        "next_steps": "Check storage class, provisioner, quota, and events for this PVC."
      }
  ]
')

echo "$issues_json" > "$OUTPUT_FILE"

echo "PVC summary (Airflow-related):"
echo "$pvc_json" | jq -r --arg used "$used_claims" '
  def claim_in_use($name):
    (($used | split("|")) | map(select(length > 0)) | index($name)) != null;
  [.items[]? | select(
      claim_in_use(.metadata.name) or
      (.metadata.name | test("dags|logs|plugins|airflow|git-sync|persistence"; "i"))
    )
    | [.metadata.name, .status.phase, (.spec.resources.requests.storage // "-")] | @tsv
  ] | .[]'
