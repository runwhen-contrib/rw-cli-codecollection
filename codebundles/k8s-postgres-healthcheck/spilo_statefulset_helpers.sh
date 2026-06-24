#!/bin/bash
# Shared helpers for bare Spilo StatefulSet deployments (apps/v1, no operator CRD).
# Sourced by connection_health.sh, core_metrics.sh, backup_health.sh, config_health.sh, dbquery.sh.

is_spilo_statefulset() {
  [[ "${OBJECT_KIND:-}" == *"statefulset"* ]]
}

# Return running pod names for this StatefulSet (pods named ${OBJECT_NAME}-<ordinal>).
_spilo_statefulset_pod_names() {
  ${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
    -l application=spilo \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "^${OBJECT_NAME}-" || true
}

# Find a pod by Patroni spilo-role label, scoped to this StatefulSet's members.
_spilo_statefulset_pod_by_role() {
  local role="$1"
  ${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
    -l "application=spilo,spilo-role=${role}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "^${OBJECT_NAME}-" | head -1
}

# Find a suitable Spilo pod for this StatefulSet.
# Usage: find_spilo_statefulset_pod [prefer_replica=true|false]
# Prints: pod_name|container
find_spilo_statefulset_pod() {
  local prefer_replica="${1:-false}"
  local pod_name=""
  local container="${DATABASE_CONTAINER:-postgres}"

  if [[ "$prefer_replica" == "true" ]]; then
    pod_name=$(_spilo_statefulset_pod_by_role replica)
  fi

  if [[ -z "$pod_name" ]]; then
    pod_name=$(_spilo_statefulset_pod_by_role master)
  fi
  if [[ -z "$pod_name" ]]; then
    pod_name=$(_spilo_statefulset_pod_by_role primary)
  fi
  if [[ -z "$pod_name" ]]; then
    pod_name=$(_spilo_statefulset_pod_names | head -1)
  fi
  if [[ -z "$pod_name" ]]; then
    local ordinal="${OBJECT_NAME}-0"
    if ${KUBERNETES_DISTRIBUTION_BINARY} get pod "$ordinal" -n "$NAMESPACE" --context "$CONTEXT" \
      --field-selector=status.phase=Running &>/dev/null; then
      pod_name="$ordinal"
    fi
  fi

  echo "${pod_name}|${container}"
}
