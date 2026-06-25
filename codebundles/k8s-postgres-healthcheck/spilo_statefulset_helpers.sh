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
      --field-selector=status.phase=Running -o name &>/dev/null; then
      pod_name="$ordinal"
    fi
  fi

  if [[ -z "$pod_name" ]]; then
    pod_name=$(_spilo_statefulset_pod_via_patronictl "$prefer_replica")
  fi

  echo "${pod_name}|${container}"
}

# Fallback: ask patronictl on any reachable member for Leader/Replica pod names.
_spilo_statefulset_pod_via_patronictl() {
  local prefer_replica="${1:-false}"
  local seed=""
  local container="${DATABASE_CONTAINER:-postgres}"

  seed=$(_spilo_statefulset_pod_names | head -1)
  if [[ -z "$seed" && -n "${WORKLOAD_NAME:-}" && "${WORKLOAD_NAME}" != -* ]]; then
    seed="$WORKLOAD_NAME"
  fi
  if [[ -z "$seed" ]]; then
    seed="${OBJECT_NAME}-0"
  fi

  if ! ${KUBERNETES_DISTRIBUTION_BINARY} get pod "$seed" -n "$NAMESPACE" --context "$CONTEXT" \
    --field-selector=status.phase=Running -o name &>/dev/null; then
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    return 1
  fi

  local json=""
  json=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$seed" --context "$CONTEXT" -c "$container" \
    -- patronictl list -f json 2>/dev/null) || true

  if [[ -z "$json" ]] || ! echo "$json" | jq -e 'type == "array" and length > 0' &>/dev/null; then
    return 1
  fi

  local pod_name=""
  if [[ "$prefer_replica" == "true" ]]; then
    pod_name=$(echo "$json" | jq -r '.[] | select((.Role|ascii_downcase)|test("replica")) | .Member' \
      | grep "^${OBJECT_NAME}-" | head -1)
  fi
  if [[ -z "$pod_name" ]]; then
    pod_name=$(echo "$json" | jq -r '.[] | select((.Role|ascii_downcase)|test("leader|master|primary")) | .Member' \
      | grep "^${OBJECT_NAME}-" | head -1)
  fi
  if [[ -z "$pod_name" ]]; then
    pod_name=$(echo "$json" | jq -r '.[0].Member // empty' | grep "^${OBJECT_NAME}-" | head -1)
  fi

  [[ -n "$pod_name" ]] && echo "$pod_name"
}
