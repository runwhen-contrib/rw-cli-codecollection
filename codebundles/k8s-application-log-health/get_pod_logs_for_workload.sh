#!/usr/bin/env bash
#
# Usage:
#   ./get_pods_for_workload_fulljson.sh <WORKLOAD_TYPE> <WORKLOAD_NAME> <NAMESPACE> <CONTEXT>
#
# Examples:
#   ./get_pods_for_workload_fulljson.sh deployment my-deployment my-namespace my-context
#   ./get_pods_for_workload_fulljson.sh statefulset my-statefulset my-namespace my-context
#
# Output: Pure valid JSON array of the matching Pod objects, e.g.:
# [
#   {
#     "metadata": { ... },
#     "spec": { ... },
#     "status": { ... }
#   },
#   {
#     "metadata": { ... },
#     "spec": { ... },
#     "status": { ... }
#   }
# ]

WORKLOAD_TYPE="${1:-$WORKLOAD_TYPE}"   # "deployment", "statefulset", or "daemonset"
WORKLOAD_NAME="${2:-$WORKLOAD_NAME}"
NAMESPACE="${3:-$NAMESPACE}"
CONTEXT="${4:-$CONTEXT}"
LOG_LINES=${5:-10000}
OUTPUT_FILE=$OUTPUT_DIR/application_logs_pods.json
IGNORE_JSON="ignore_patterns.json"      # the file with skip patterns


# 1) Fetch the workload as JSON, extract its UID
WORKLOAD_JSON=$(kubectl get "${WORKLOAD_TYPE}" "${WORKLOAD_NAME}" \
  -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null) || {
  echo "Error: Failed to get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in ${NAMESPACE}." >&2
  exit 1
}

WORKLOAD_UID=$(echo "${WORKLOAD_JSON}" | jq -r '.metadata.uid')
if [[ -z "${WORKLOAD_UID}" || "${WORKLOAD_UID}" == "null" ]]; then
  echo "Error: Could not find UID for ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}." >&2
  exit 1
fi

# 2) Collect all relevant Pods
# For a Deployment, we must gather ReplicaSet UIDs and then filter Pods.
# For a StatefulSet/DaemonSet, they directly own their Pods.

if [[ "${WORKLOAD_TYPE,,}" == "deployment" ]]; then
  # Get all ReplicaSets in JSON
  RS_JSON=$(kubectl get replicaset -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null) || {
    echo "Error: Failed to list ReplicaSets in ${NAMESPACE}." >&2
    exit 1
  }

  # Extract the UIDs of ReplicaSets owned by this Deployment
  RS_UIDS=$(echo "${RS_JSON}" | jq -r --arg DEP_UID "${WORKLOAD_UID}" '
    .items[]
    | select(.metadata.ownerReferences[]? | .uid == $DEP_UID)
    | .metadata.uid
  ')

  # Convert the ReplicaSet UIDs into a single jq "OR" expression
  # e.g. if RS_UIDS has 2 lines: "aaa-111" and "bbb-222",
  # we'll produce: (.metadata.ownerReferences[]?.uid == "aaa-111") or (.metadata.ownerReferences[]?.uid == "bbb-222")
  JQ_OR_EXPRESSION=""
  while IFS= read -r rs_uid; do
    [[ -z "$rs_uid" ]] && continue
    if [[ -n "${JQ_OR_EXPRESSION}" ]]; then
      JQ_OR_EXPRESSION+=" or (.metadata.ownerReferences[]?.uid == \"$rs_uid\")"
    else
      JQ_OR_EXPRESSION="(.metadata.ownerReferences[]?.uid == \"$rs_uid\")"
    fi
  done <<< "${RS_UIDS}"

  # If we found no ReplicaSets, we can just output an empty array
  if [[ -z "${JQ_OR_EXPRESSION}" ]]; then
    echo "[]"
    exit 0
  fi

  # Now get all Pods in the namespace and filter by that JQ expression
  # Return as a JSON array of full Pod objects
  kubectl get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json \
  | jq --argjson nullObj null '
      .items
      | map(select('"${JQ_OR_EXPRESSION}"'))
      '   > $OUTPUT_FILE

else
  # For StatefulSet, DaemonSet: directly own Pods with an ownerReference of the workload's UID
  kubectl get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json \
  | jq --arg OWNER_UID "${WORKLOAD_UID}" '
      .items
      | map(
          select(.metadata.ownerReferences[]? | .uid == $OWNER_UID)
        )
    ' > $OUTPUT_FILE
fi

###################################### 
### Log Fetching and Pre Filtering ###
###################################### 


# 1) Build a single combined 'OR' expression from ignore_patterns.json
#    We'll read all "match" fields and join them with '|'
IGNORE_EXPR=""
while IFS= read -r skip_pattern; do
  [[ -z "$skip_pattern" ]] && continue
  # If IGNORE_EXPR is not empty, append '|'
  if [[ -n "$IGNORE_EXPR" ]]; then
    IGNORE_EXPR+="|$skip_pattern"
  else
    IGNORE_EXPR="$skip_pattern"
  fi
done < <(jq -r '.patterns[].match' "$IGNORE_JSON")

# If we have any patterns, wrap them in parentheses
# e.g. (patternA|patternB)
if [[ -n "$IGNORE_EXPR" ]]; then
  IGNORE_EXPR="(${IGNORE_EXPR})"
  echo "Combined ignore expression: $IGNORE_EXPR"
else
  echo "No ignore patterns found. Will store raw logs."
fi

# 2) Gather pods from application_logs_pods.json
PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

# 3) Prepare a local directory for the logs
LOGS_DIR="${OUTPUT_DIR}/${WORKLOAD_TYPE}_${WORKLOAD_NAME}_logs"
rm -rf "${LOGS_DIR}" || true
mkdir -p "${LOGS_DIR}"

# 4) Iterate over each Pod, fetch logs for each container
for POD in "${PODS[@]}"; do
    echo "Processing Pod: $POD"

    # Extract container names from the local JSON (instead of kubectl):
    CONTAINERS=$(jq -r --arg POD "$POD" '
      .[] | select(.metadata.name == $POD)
      | .spec.containers[].name
    ' "${OUTPUT_DIR}/application_logs_pods.json")

    for CONTAINER in ${CONTAINERS}; do
        echo "  Container: $CONTAINER"

        LOG_FILE="${LOGS_DIR}/${POD}_${CONTAINER}_logs.txt"

        # 4a) Current logs
        # Pipe through grep -vP to remove ignore patterns
        if [[ -n "$IGNORE_EXPR" ]]; then
          kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" \
              --tail="${LOG_LINES}" --timestamps 2>/dev/null \
            | grep -vP "$IGNORE_EXPR" \
            > "${LOG_FILE}"
        else
          # If no ignore patterns, store raw logs
          kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" \
              --tail="${LOG_LINES}" --timestamps 2>/dev/null \
            > "${LOG_FILE}"
        fi

        # 4b) Previous logs (if any)
        if [[ -n "$IGNORE_EXPR" ]]; then
          kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" \
              --tail="${LOG_LINES}" --timestamps --previous 2>/dev/null \
            | grep -vP "$IGNORE_EXPR" \
            >> "${LOG_FILE}"
        else
          kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" \
              --tail="${LOG_LINES}" --timestamps --previous 2>/dev/null \
            >> "${LOG_FILE}"
        fi
    done
done

echo "Done. Logs stored in: ${LOGS_DIR}"