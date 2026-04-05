#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Writes JSON array of issues to verify_statefulset_issues.json (empty if OK).
# Required env: CONTEXT, NAMESPACE, STATEFULSET_NAME, KUBERNETES_DISTRIBUTION_BINARY
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${STATEFULSET_NAME:?Must set STATEFULSET_NAME}"

OUTPUT_FILE="verify_statefulset_issues.json"
issues_json='[]'

if ! err=$("${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}" get "statefulset/${STATEFULSET_NAME}" \
  -n "${NAMESPACE}" --context "${CONTEXT}" -o name 2>&1); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot access StatefulSet \`${STATEFULSET_NAME}\`" \
    --arg details "kubectl get statefulset failed: ${err}" \
    --arg severity "3" \
    --arg next_steps "Verify kubeconfig, RBAC, namespace, and StatefulSet name." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "verify-statefulset-access: wrote ${OUTPUT_FILE}"
