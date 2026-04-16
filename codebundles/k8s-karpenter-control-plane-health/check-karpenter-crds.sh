#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists installed CRDs whose group/name relate to Karpenter (multi-cloud).
# Writes JSON array to crds_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="crds_issues.json"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
issues_json='[]'

if ! crds=$("${KUBECTL}" get crds -o json --context "${CONTEXT}" 2>/dev/null); then
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot list CustomResourceDefinitions" \
    --arg details "kubectl get crds failed; verify cluster access." \
    --argjson severity 4 \
    --arg next_steps "Check kubeconfig and RBAC for crd.list" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

groups=$(echo "$crds" | jq -r '.items[] | select(.spec.group | test("karpenter"; "i")) | .spec.group' | sort -u)
group_count=$(echo "$groups" | grep -cve '^$' || true)

if [[ "${group_count:-0}" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Karpenter CRD API groups detected" \
    --arg details "Expected groups such as karpenter.sh or karpenter.k8s.aws; none found." \
    --argjson severity 3 \
    --arg next_steps "Install or upgrade Karpenter CRDs from https://karpenter.sh/docs/" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
else
  # Informational: multiple top-level Karpenter API groups may indicate mixed versions
  if [[ "$group_count" -gt 2 ]]; then
    summary=$(echo "$groups" | paste -sd, -)
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Multiple Karpenter-related CRD groups installed (${group_count})" \
      --arg details "Groups: ${summary}" \
      --argjson severity 4 \
      --arg next_steps "Confirm only one Karpenter major version is intended; remove stale CRDs from old installs." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
fi

echo "$issues_json" >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
