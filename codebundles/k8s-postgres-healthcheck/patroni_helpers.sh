#!/bin/bash
# Shared helpers for resolving postgres exec targets and running patronictl.

if [[ -f spilo_statefulset_helpers.sh ]]; then
  # shellcheck disable=SC1091
  source spilo_statefulset_helpers.sh
fi

# Resolve WORKLOAD_NAME to a running pod name for kubectl exec.
# WORKLOAD_NAME may be a label selector (-l ...), a pod name, or a pod name prefix.
resolve_workload_exec_pod() {
  local pod_name=""

  if [[ "${WORKLOAD_NAME:-}" == -* ]]; then
    pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods ${WORKLOAD_NAME} -n "$NAMESPACE" --context "$CONTEXT" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | tr -d '[:space:]')
  elif [[ -n "${WORKLOAD_NAME:-}" ]] && \
    ${KUBERNETES_DISTRIBUTION_BINARY} get pod "$WORKLOAD_NAME" -n "$NAMESPACE" --context "$CONTEXT" \
      --field-selector=status.phase=Running -o name &>/dev/null; then
    pod_name="$WORKLOAD_NAME"
  elif [[ -n "${WORKLOAD_NAME:-}" ]]; then
    pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods "$WORKLOAD_NAME" -n "$NAMESPACE" --context "$CONTEXT" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | tr -d '[:space:]')
  fi

  if [[ -z "$pod_name" ]] && declare -F is_spilo_statefulset &>/dev/null && is_spilo_statefulset 2>/dev/null; then
    local pod_info
    pod_info=$(find_spilo_statefulset_pod "false")
    pod_name=$(echo "$pod_info" | cut -d'|' -f1 | tr -d '[:space:]')
  fi

  echo "$pod_name"
}

# Run patronictl list (text) on a pod; prints combined stdout/stderr.
patronictl_list_text() {
  local pod="$1"
  local container="${DATABASE_CONTAINER:-postgres}"
  ${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod" --context "$CONTEXT" -c "$container" \
    -- patronictl list 2>&1
}

# Return patronictl members as a JSON array. Tries -f json first, then parses text output.
patronictl_list_members_json() {
  local pod="$1"
  local container="${DATABASE_CONTAINER:-postgres}"
  local json_out=""

  json_out=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod" --context "$CONTEXT" -c "$container" \
    -- patronictl list -f json 2>/dev/null | tr -d '\r')

  if [[ -n "$json_out" ]] && command -v jq &>/dev/null && echo "$json_out" | jq -e 'type == "array" and length > 0' &>/dev/null; then
    echo "$json_out"
    return 0
  fi

  local text_out
  text_out=$(patronictl_list_text "$pod")
  if [[ -z "$text_out" ]]; then
    echo "[]"
    return 1
  fi

  if command -v python3 &>/dev/null; then
    PATRONI_TEXT="$text_out" OBJECT_NAME="${OBJECT_NAME:-}" python3 - <<'PY'
import json, os, re

text = os.environ.get("PATRONI_TEXT", "")
object_name = os.environ.get("OBJECT_NAME", "")
cluster_name = object_name
for line in text.splitlines():
    match = re.search(r"Cluster:\s+(\S+)", line)
    if match:
        cluster_name = match.group(1)
        break

members = []
for line in text.splitlines():
    if "|" not in line or line.strip().startswith("+"):
        continue
    parts = [p.strip() for p in line.split("|")]
    if len(parts) < 7:
        continue
    member, host, role = parts[1], parts[2], parts[3]
    if not member or member in {"Member", "Host"} or member.startswith("-"):
        continue
    lag_raw = parts[6] if len(parts) > 6 else ""
    lag_match = re.search(r"[\d.]+", lag_raw or "")
    lag = float(lag_match.group()) if lag_match else 0.0
    members.append({
        "Member": member,
        "Cluster": cluster_name or host,
        "Role": role,
        "Lag in MB": lag,
    })
print(json.dumps(members))
PY
    return $?
  fi

  echo "[]"
  return 1
}
