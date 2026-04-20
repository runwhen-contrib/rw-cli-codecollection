#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive one autoscaling-health test scenario end-to-end:
#   1. Apply the scenario's fixture (if any) and patch .status subresources
#      on the objects that need a specific condition shape.
#   2. Wait briefly for the cluster to settle.
#   3. Run the relevant CodeBundle check script(s) against the test cluster.
#   4. Assert expected issue titles in the emitted *_issues.json files.
#   5. Remove the fixture and any label-scoped leftover so the next scenario
#      starts from a clean baseline.
#
# Args:
#   $1 - scenario name (required)
#   $2 - kubectl context (required)
#   $3 - Karpenter namespace (default: karpenter)
# ---------------------------------------------------------------------------
set -euo pipefail

SCENARIO="${1:?scenario name required}"
CONTEXT="${2:?kubectl context required}"
NS="${3:-karpenter}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_DIR="$(cd "${TEST_DIR}/.." && pwd)"
EXPECT="${TEST_DIR}/assertions/expect-issue.sh"
FIXTURE_DIR="${TEST_DIR}/kubernetes/fixtures"

RUN_DIR="${TEST_DIR}/output/${SCENARIO}"
mkdir -p "${RUN_DIR}"

log() { echo "[${SCENARIO}] $*" >&2; }

export CONTEXT="${CONTEXT}"
export KARPENTER_NAMESPACE="${NS}"
export KUBERNETES_DISTRIBUTION_BINARY="kubectl"
export RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-30m}"

run_check() {
  local script="$1" output_name="$2"
  shift 2
  log "running ${script} -> ${output_name}"
  ( cd "${RUN_DIR}" && env "$@" bash "${BUNDLE_DIR}/${script}" >/dev/null 2>"${RUN_DIR}/${script}.stderr" )
  echo "${RUN_DIR}/${output_name}"
}

apply_fixture() { kubectl --context "${CONTEXT}" apply -f "${FIXTURE_DIR}/$1"; }

delete_fixture() {
  kubectl --context "${CONTEXT}" delete -f "${FIXTURE_DIR}/$1" \
    --ignore-not-found --wait=true >/dev/null
}

reset_events() {
  kubectl --context "${CONTEXT}" -n "${NS}" delete events --all \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Patch .status.conditions on any cluster-scoped resource, using the status
# subresource. jq builds the condition array from name=value arguments.
patch_status_conditions() {
  local resource="$1" name="$2"; shift 2
  local conds
  conds=$(jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --args '
    [$ARGS.positional[] | split("=")
      | {type: .[0], status: .[1], reason: (.[2] // ""), message: (.[3] // ""), lastTransitionTime: $now}]
  ' -- "$@")
  kubectl --context "${CONTEXT}" patch "${resource}" "${name}" \
    --subresource=status --type=merge \
    -p "$(jq -n --argjson c "$conds" '{status: {conditions: $c}}')"
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario_healthy() {
  log "asserting clean baseline..."
  local f
  f=$(run_check "check-karpenter-nodepool-nodeclaim-status.sh" "karpenter_nodepool_nodeclaim_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "check-karpenter-nodeclass-conditions.sh" "karpenter_nodeclass_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "check-pending-provisioning-workloads.sh" "karpenter_pending_workload_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "check-stuck-nodeclaims.sh" "karpenter_stuck_nodeclaim_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "scan-karpenter-controller-logs.sh" "karpenter_controller_log_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "correlate-karpenter-logs-pending-pods.sh" "karpenter_correlation_issues.json")
  "${EXPECT}" --empty "${f}"
}

scenario_nodepool_unhealthy() {
  apply_fixture nodepool-unhealthy.yaml
  patch_status_conditions nodepool broken-pool \
    "Ready=False=ConfigBroken=simulated failure for test"
  sleep 2
  local f
  f=$(run_check "check-karpenter-nodepool-nodeclaim-status.sh" "karpenter_nodepool_nodeclaim_issues.json")
  "${EXPECT}" "${f}" "NodePool \`broken-pool\` condition \`Ready\` is False"
  delete_fixture nodepool-unhealthy.yaml
}

scenario_nodeclaim_not_registered() {
  apply_fixture nodeclaim-not-registered.yaml
  patch_status_conditions nodeclaim nc-not-registered \
    "Registered=False=NotYetRegistered=kubelet never joined"
  sleep 2
  local f
  f=$(run_check "check-karpenter-nodepool-nodeclaim-status.sh" "karpenter_nodepool_nodeclaim_issues.json")
  "${EXPECT}" "${f}" "NodeClaim \`nc-not-registered\` condition \`Registered\` is False"
  delete_fixture nodeclaim-not-registered.yaml
}

scenario_node_not_ready() {
  apply_fixture node-not-ready.yaml
  # No KWOK annotation on this node, so we must patch status ourselves to
  # have a deterministic Ready=False condition. Without a patch, the check
  # falls back to "Unknown" (which also triggers the issue), but this is
  # clearer intent.
  patch_status_conditions node offline-node-0 \
    "Ready=False=KubeletDown=test fixture: kubelet not running"
  sleep 1
  local f
  f=$(run_check "check-karpenter-nodepool-nodeclaim-status.sh" "karpenter_nodepool_nodeclaim_issues.json")
  "${EXPECT}" "${f}" "Node \`offline-node-0\` is not Ready"
  delete_fixture node-not-ready.yaml
}

scenario_node_cordoned() {
  apply_fixture node-cordoned.yaml
  # KWOK drives the node to Ready=True automatically; spec.unschedulable=true
  # comes from the manifest.
  sleep 2
  local f
  f=$(run_check "check-karpenter-nodepool-nodeclaim-status.sh" "karpenter_nodepool_nodeclaim_issues.json")
  "${EXPECT}" "${f}" "Node \`kwok-cordoned-0\` is cordoned"
  delete_fixture node-cordoned.yaml
}

scenario_pending_pod() {
  apply_fixture pending-pod.yaml
  # Give the scheduler a beat to produce a FailedScheduling condition.
  sleep 5
  local f
  f=$(run_check "check-pending-provisioning-workloads.sh" "karpenter_pending_workload_issues.json")
  "${EXPECT}" "${f}" "suggests scheduling or capacity pressure"
  delete_fixture pending-pod.yaml
}

scenario_stuck_nodeclaim() {
  apply_fixture stuck-nodeclaim.yaml
  # Don't patch status - no Ready=True means "stuck" when threshold is 0.
  sleep 1
  local f
  f=$(run_check "check-stuck-nodeclaims.sh" "karpenter_stuck_nodeclaim_issues.json" \
    "STUCK_NODECLAIM_THRESHOLD_MINUTES=0")
  "${EXPECT}" "${f}" "NodeClaim \`nc-stuck\` not Ready after 0 minutes"
  delete_fixture stuck-nodeclaim.yaml
}

scenario_stuck_nodeclaim_deleting() {
  apply_fixture stuck-nodeclaim-deleting.yaml
  # Delete without waiting - finalizer keeps the object alive with a
  # deletionTimestamp set. That's the "stuck deleting" signal.
  kubectl --context "${CONTEXT}" delete nodeclaim nc-stuck-deleting \
    --wait=false >/dev/null
  sleep 1
  local f
  f=$(run_check "check-stuck-nodeclaims.sh" "karpenter_stuck_nodeclaim_issues.json")
  "${EXPECT}" "${f}" "nc-stuck-deleting" "stuck deleting"
  # Remove the finalizer so the object can be cleaned up.
  kubectl --context "${CONTEXT}" patch nodeclaim nc-stuck-deleting \
    --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || true
  kubectl --context "${CONTEXT}" delete nodeclaim nc-stuck-deleting \
    --ignore-not-found --wait=true >/dev/null
}

scenario_ec2nodeclass_degraded() {
  apply_fixture ec2nodeclass-degraded.yaml
  patch_status_conditions ec2nodeclass degraded-ec2-class \
    "Ready=False=SubnetSelectorMismatch=no subnets matched tag selectors"
  sleep 2
  local f
  f=$(run_check "check-karpenter-nodeclass-conditions.sh" "karpenter_nodeclass_issues.json")
  "${EXPECT}" "${f}" "EC2NodeClass \`degraded-ec2-class\` condition \`Ready\` is False"
  delete_fixture ec2nodeclass-degraded.yaml
}

scenario_controller_logs_errors() {
  apply_fixture controller-logs-errors.yaml
  # Wait for the noisy pod to log at least a few lines.
  wait_for_pod_logs "controller-logs-errors" karpenter-noisy-logs "UnauthorizedOperation"
  local f
  f=$(run_check "scan-karpenter-controller-logs.sh" "karpenter_controller_log_issues.json")
  "${EXPECT}" "${f}" "Karpenter controller logs:"
  delete_fixture controller-logs-errors.yaml
}

scenario_log_correlation() {
  apply_fixture log-correlation.yaml
  wait_for_pod_logs "log-correlation" karpenter-correlating "myapp-pending-abc"
  local f
  f=$(run_check "correlate-karpenter-logs-pending-pods.sh" "karpenter_correlation_issues.json")
  "${EXPECT}" "${f}" "Log correlation: pending pod" "myapp-pending-abc"
  delete_fixture log-correlation.yaml
}

# Wait until `kubectl logs <pod>` in the karpenter ns contains <pattern>.
# Args: <scenario-label> <pod-name> <grep-pattern>
wait_for_pod_logs() {
  local label="$1" pod="$2" pat="$3"
  local deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    if kubectl --context "${CONTEXT}" -n "${NS}" logs "${pod}" 2>/dev/null | grep -qF "${pat}"; then
      return 0
    fi
    sleep 2
  done
  log "TIMEOUT waiting for '${pat}' in logs of pod ${pod}"
  return 1
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
reset_events
case "${SCENARIO}" in
  healthy)                     scenario_healthy ;;
  nodepool-unhealthy)          scenario_nodepool_unhealthy ;;
  nodeclaim-not-registered)    scenario_nodeclaim_not_registered ;;
  node-not-ready)              scenario_node_not_ready ;;
  node-cordoned)               scenario_node_cordoned ;;
  pending-pod)                 scenario_pending_pod ;;
  stuck-nodeclaim)             scenario_stuck_nodeclaim ;;
  stuck-nodeclaim-deleting)    scenario_stuck_nodeclaim_deleting ;;
  ec2nodeclass-degraded)       scenario_ec2nodeclass_degraded ;;
  controller-logs-errors)      scenario_controller_logs_errors ;;
  log-correlation)             scenario_log_correlation ;;
  *)
    echo "Unknown scenario: ${SCENARIO}" >&2
    exit 2
    ;;
esac

log "PASS"
