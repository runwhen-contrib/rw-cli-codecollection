#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# Outputs issues to check_pdb_rollout_impact.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"

OUTPUT_FILE="check_pdb_rollout_impact.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Checking PDB impact on rollout for deployment ${DEPLOYMENT_NAME}"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

match_labels=$(echo "$DEPLOYMENT_JSON" | jq -c '.spec.selector.matchLabels // {}')
replicas=$(echo "$DEPLOYMENT_JSON" | jq '.spec.replicas // 0')
ready_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.readyReplicas // 0')

PDB_JSON=$("${K8S_CMD[@]}" get pdb -o json 2>/dev/null || echo '{"items":[]}')

matching_pdbs=$(echo "$PDB_JSON" | jq --argjson labels "$match_labels" \
    '[.items[] | select(.spec.selector.matchLabels as $pdb_labels |
        ($labels | to_entries | all(.key as $k | .value as $v | $pdb_labels[$k] == $v)))]')

pdb_count=$(echo "$matching_pdbs" | jq 'length')
echo "Found ${pdb_count} matching PDB(s)"

if [[ "$pdb_count" -eq 0 ]]; then
    echo "No PodDisruptionBudgets match deployment selector."
    write_issues "$OUTPUT_FILE"
    exit 0
fi

while IFS= read -r pdb_name; do
    [[ -z "$pdb_name" ]] && continue
    pdb_detail=$(echo "$matching_pdbs" | jq --arg name "$pdb_name" '.[] | select(.metadata.name==$name)')
    min_available=$(echo "$pdb_detail" | jq -r '.spec.minAvailable // empty')
    max_unavailable=$(echo "$pdb_detail" | jq -r '.spec.maxUnavailable // empty')
    disruptions_allowed=$(echo "$pdb_detail" | jq -r '.status.disruptionsAllowed // 0')
    current_healthy=$(echo "$pdb_detail" | jq -r '.status.currentHealthy // 0')
    desired_healthy=$(echo "$pdb_detail" | jq -r '.status.desiredHealthy // 0')

    echo "PDB ${pdb_name}: minAvailable=${min_available:-n/a}, maxUnavailable=${max_unavailable:-n/a}, disruptionsAllowed=${disruptions_allowed}"

    if [[ "$disruptions_allowed" == "0" && "$replicas" -gt 0 ]]; then
        add_issue "2" \
            "PDB \`${pdb_name}\` Blocks Pod Eviction During Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "PDB ${pdb_name} allows 0 disruptions (currentHealthy=${current_healthy}, desiredHealthy=${desired_healthy}, minAvailable=${min_available:-unset}, maxUnavailable=${max_unavailable:-unset}). Ready replicas=${ready_replicas}, desired=${replicas}." \
            "Temporarily relax PDB minAvailable/maxUnavailable or scale deployment carefully. Scale Down Stale ReplicaSets after resolving constraints."
    fi

    if [[ -n "$min_available" && "$min_available" =~ ^[0-9]+$ ]]; then
        if [[ "$replicas" -le "$min_available" ]]; then
            add_issue "3" \
                "PDB \`${pdb_name}\` minAvailable Prevents Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
                "minAvailable=${min_available} with deployment replicas=${replicas} leaves no room to terminate old pods during rolling update." \
                "Increase replica count or adjust PDB minAvailable to allow at least one pod disruption during rollout."
        fi
    fi

    if [[ -n "$min_available" && "$min_available" =~ ^[0-9]+%$ ]]; then
        pct=${min_available%\%}
        required=$(( (replicas * pct + 99) / 100 ))
        if [[ "$required" -ge "$replicas" && "$replicas" -gt 0 ]]; then
            add_issue "3" \
                "PDB \`${pdb_name}\` Percentage minAvailable May Block Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
                "minAvailable=${min_available} requires ${required} of ${replicas} pods available, leaving no eviction budget." \
                "Review PDB percentage relative to replica count during rollouts."
        fi
    fi
done < <(echo "$matching_pdbs" | jq -r '.[].metadata.name')

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
