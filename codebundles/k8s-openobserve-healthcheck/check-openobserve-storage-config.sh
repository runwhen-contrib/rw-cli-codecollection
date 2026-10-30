#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Reads the OpenObserve workload env/config for storage topology
# (ZO_LOCAL_MODE, ZO_DATA_DIR, ZO_S3_*) and validates that S3 settings exist
# when local mode is disabled. Purely kubectl-level; never inspects storage
# from inside a container.
#
# Required env: CONTEXT, NAMESPACE
# Optional: OBJECT_NAME, KUBERNETES_DISTRIBUTION_BINARY
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
KBIN="$KUBERNETES_DISTRIBUTION_BINARY"
OUTPUT_FILE="${OUTPUT_FILE:-openobserve_storage_config_issues.json}"
issues_json='[]'
: >"$OUTPUT_FILE.tmp"

echo "--- OpenObserve storage configuration audit in namespace ${NAMESPACE} (context ${CONTEXT}) ---"

workloads=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get deploy,sts -o json 2>/dev/null \
  | jq -c '[.items[] | select(.metadata.name | test("openobserve"; "i"))]' 2>/dev/null || echo "[]")

count=$(echo "$workloads" | jq -r 'length' 2>/dev/null || echo 0)
if [[ "$count" -eq 0 ]]; then
  echo "No OpenObserve workloads found; nothing to audit."
  jq -n \
    --arg title "No OpenObserve workloads found for storage config audit" \
    --arg details "No Deployment or StatefulSet whose name contains 'openobserve' exists in namespace ${NAMESPACE}." \
    --argjson severity 3 \
    --arg next_steps "Verify the namespace and confirm the OpenObserve workload is deployed." \
    '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
else
  # Extract merged container env (first container) for informational output.
  echo "$workloads" | jq -c '.[]' | while IFS= read -r wl; do
    kind=$(echo "$wl" | jq -r '.kind')
    name=$(echo "$wl" | jq -r '.metadata.name')
    container=$(echo "$wl" | jq -r '.spec.template.spec.containers[0] // empty')
    if [[ -z "$container" ]]; then
      echo "$kind ${name}: no containers found."
      continue
    fi
    echo "$kind ${name}:"

    env_list=$(echo "$container" | jq -c '[.env[]?]' 2>/dev/null || echo '[]')
    local_mode=$(echo "$env_list" | jq -r '[.[] | select(.name == "ZO_LOCAL_MODE")][0].value // ""' 2>/dev/null || true)
    data_dir=$(echo "$env_list" | jq -r '[.[] | select(.name == "ZO_DATA_DIR")][0].value // ""' 2>/dev/null || true)
    s3_names=$(echo "$env_list" | jq -r '[.[] | select(.name | startswith("ZO_S3_")) | .name] | join(", ")' 2>/dev/null || true)
    s3_keys=0
    if [[ -n "$s3_names" ]]; then
      s3_keys=$(echo "$s3_names" | awk -F', ' '{print NF}')
    fi
    echo "  ZO_LOCAL_MODE=${local_mode:-<unset>} ZO_DATA_DIR=${data_dir:-<unset>} S3 env vars (${s3_names:-<none>})"

    if [[ -z "$local_mode" ]]; then
      echo "Result: ${kind} ${name} does not set ZO_LOCAL_MODE (defaults to local mode in most OpenObserve versions)."
      jq -n --arg kind "$kind" --arg name "$name" --arg data_dir "${data_dir:-<unset>}" \
        --arg title "${kind} \`${name}\` does not set ZO_LOCAL_MODE" \
        --arg details "ZO_LOCAL_MODE is not present in the workload env (data dir: ${data_dir}). If the deployment intends to use S3 object storage, set ZO_LOCAL_MODE=false and configure ZO_S3_* settings." \
        --argjson severity 3 \
        --arg next_steps "Set ZO_LOCAL_MODE explicitly (true for local volume storage, false for S3) and add the corresponding ZO_DATA_DIR / ZO_S3_* configuration to the Helm values." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    elif [[ "$local_mode" == "false" || "$local_mode" == "False" || "$local_mode" == "FALSE" ]]; then
      if [[ "$s3_keys" -eq 0 ]]; then
        echo "Result: ${kind} ${name} runs with ZO_LOCAL_MODE=false but no ZO_S3_* settings."
        jq -n --arg kind "$kind" --arg name "$name" \
          --arg title "${kind} \`${name}\` runs with ZO_LOCAL_MODE=false but no ZO_S3_* settings" \
          --arg details "ZO_LOCAL_MODE=false but no ZO_S3_* environment variables are configured on the container. OpenObserve may fail to connect to object storage." \
          --argjson severity 3 \
          --arg next_steps "Add ZO_S3_BUCKET_NAME, ZO_S3_REGION_NAME, ZO_S3_ACCESS_KEY, ZO_S3_SECRET_KEY (or a proper S3 provider config) to the OpenObserve configuration." \
          '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
      else
        echo "Result: ${kind} ${name} storage config OK (ZO_LOCAL_MODE=false with ${s3_keys} S3 settings)."
      fi
    else
      echo "Result: ${kind} ${name} runs in local storage mode (ZO_LOCAL_MODE=${local_mode})."
    fi
  done
fi

if [[ -s "$OUTPUT_FILE.tmp" ]]; then
  issues_json=$(jq -s . "$OUTPUT_FILE.tmp" 2>/dev/null || echo '[]')
  rm -f "$OUTPUT_FILE.tmp"
else
  issues_json='[]'
  rm -f "$OUTPUT_FILE.tmp"
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve storage configuration audit complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"