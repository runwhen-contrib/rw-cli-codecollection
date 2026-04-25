#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive one test scenario end-to-end:
#   1. Apply the scenario's fixture (if any)
#   2. Wait for the cluster state the fixture is supposed to induce
#   3. Run the relevant CodeBundle check script(s) against the test cluster
#   4. Assert expected issue titles in the emitted *_issues.json
#   5. Remove the fixture so subsequent scenarios start from the clean baseline
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

# ---------------------------------------------------------------------------
# Helper: run a bundle shell script inside RUN_DIR so it writes its JSON
# output there. Returns the absolute path to the produced JSON file.
# ---------------------------------------------------------------------------
run_check() {
  local script="$1" output_name="$2"
  log "running ${script} -> ${output_name}"
  ( cd "${RUN_DIR}" && bash "${BUNDLE_DIR}/${script}" >/dev/null 2>"${RUN_DIR}/${script}.stderr" )
  echo "${RUN_DIR}/${output_name}"
}

apply_fixture() {
  local file="$1"
  kubectl --context "${CONTEXT}" apply -f "${FIXTURE_DIR}/${file}"
}

delete_fixture() {
  # Wait for resources to fully delete so the next scenario's healthy
  # baseline isn't polluted by Terminating pods / lingering Services.
  local file="$1"
  kubectl --context "${CONTEXT}" delete -f "${FIXTURE_DIR}/${file}" \
    --ignore-not-found --wait=true >/dev/null
}

reset_events() {
  # Kubernetes retains Events for ~1h by default, which leaks fixture state
  # across scenarios (e.g. a crashloop pod's FailedCreate / BackOff events
  # would survive into the next scenario_healthy run). Wipe them before each
  # scenario so every test starts from an identical event baseline.
  kubectl --context "${CONTEXT}" -n "${NS}" delete events --all \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

wait_for() {
  # wait_for <seconds> <description> <bash-test-expr>
  local deadline=$(( $(date +%s) + $1 ))
  local desc="$2"; shift 2
  while (( $(date +%s) < deadline )); do
    if eval "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  log "TIMEOUT waiting for: ${desc}"
  return 1
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario_healthy() {
  log "asserting clean baseline..."
  local f
  f=$(run_check "check-karpenter-controller-pods.sh" "controller_pods_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "check-karpenter-webhooks.sh" "webhook_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "check-karpenter-crds.sh" "crds_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "check-karpenter-service-metrics.sh" "service_metrics_issues.json")
  "${EXPECT}" --empty "${f}"
  f=$(run_check "karpenter-namespace-warning-events.sh" "warning_events_issues.json")
  "${EXPECT}" --empty "${f}"
}

scenario_crashloop_pod() {
  apply_fixture crashloop-pod.yaml
  wait_for 90 "crashloop pod to enter CrashLoopBackOff" \
    "kubectl --context '${CONTEXT}' -n '${NS}' get pod karpenter-crashloop -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -qx CrashLoopBackOff"
  local f
  f=$(run_check "check-karpenter-controller-pods.sh" "controller_pods_issues.json")
  "${EXPECT}" "${f}" "is in CrashLoopBackOff"
  delete_fixture crashloop-pod.yaml
}

scenario_replica_gap() {
  apply_fixture replica-gap-deploy.yaml
  # The Deployment will never satisfy replicas because of the unsatisfiable
  # nodeSelector; give the status a moment to settle.
  sleep 5
  local f
  f=$(run_check "check-karpenter-controller-pods.sh" "controller_pods_issues.json")
  "${EXPECT}" "${f}" "is not fully Ready"
  delete_fixture replica-gap-deploy.yaml
}

scenario_broken_webhook() {
  apply_fixture broken-webhook.yaml
  sleep 2
  local f
  f=$(run_check "check-karpenter-webhooks.sh" "webhook_issues.json")
  "${EXPECT}" "${f}" \
    "missing in namespace" \
    "empty caBundle"
  delete_fixture broken-webhook.yaml
}

scenario_url_webhook_no_ca() {
  apply_fixture url-webhook-no-ca.yaml
  sleep 2
  local f
  f=$(run_check "check-karpenter-webhooks.sh" "webhook_issues.json")
  "${EXPECT}" "${f}" "uses URL without caBundle"
  delete_fixture url-webhook-no-ca.yaml
}

scenario_extra_crd_groups() {
  apply_fixture extra-crd-groups.yaml
  sleep 2
  local f
  f=$(run_check "check-karpenter-crds.sh" "crds_issues.json")
  "${EXPECT}" "${f}" "Multiple Karpenter-related CRD groups installed"
  delete_fixture extra-crd-groups.yaml
}

scenario_warning_events() {
  # Generate 6 recent Warning events so we exceed the default
  # SLI_WARNING_EVENT_THRESHOLD=5 and trigger the grouped-events task.
  # kubectl has no first-class "create warning event" subcommand, so we
  # apply raw Event objects with a current lastTimestamp.
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local now_micro; now_micro=$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)
  local ts; ts=$(date +%s)
  for i in 1 2 3 4 5 6; do
    cat <<EOF | kubectl --context "${CONTEXT}" apply -f - >/dev/null
apiVersion: v1
kind: Event
metadata:
  name: karpenter-test-${i}-${ts}
  namespace: ${NS}
  labels:
    test.runwhen.com/fixture: warning-events
type: Warning
reason: FailedCallingWebhook
message: "failed calling webhook validation.karpenter.sh: connection refused (test event ${i})"
action: RunwhenTest
involvedObject:
  apiVersion: v1
  kind: Namespace
  name: ${NS}
  namespace: ${NS}
source:
  component: runwhen-test-harness
firstTimestamp: "${now}"
lastTimestamp: "${now}"
eventTime: "${now_micro}"
reportingComponent: runwhen-test-harness
reportingInstance: scenario-runner
count: 1
EOF
  done
  sleep 2
  local f
  f=$(run_check "karpenter-namespace-warning-events.sh" "warning_events_issues.json")
  "${EXPECT}" "${f}" "Warning events"
  # Webhook check also surfaces these via the "webhook" message pattern
  f=$(run_check "check-karpenter-webhooks.sh" "webhook_issues.json")
  "${EXPECT}" "${f}" "Recent Warning event suggests webhook call failures"
  # Clean up events by label selector so we don't perturb later scenarios.
  kubectl --context "${CONTEXT}" -n "${NS}" delete events \
    -l test.runwhen.com/fixture=warning-events --ignore-not-found >/dev/null
}

scenario_svc_no_endpoints() {
  apply_fixture svc-no-endpoints.yaml
  sleep 2
  local f
  f=$(run_check "check-karpenter-service-metrics.sh" "service_metrics_issues.json")
  "${EXPECT}" "${f}" "has no endpoint addresses"
  delete_fixture svc-no-endpoints.yaml
}

scenario_svc_no_metrics_port() {
  apply_fixture svc-no-metrics-port.yaml
  sleep 2
  local f
  f=$(run_check "check-karpenter-service-metrics.sh" "service_metrics_issues.json")
  "${EXPECT}" "${f}" "may not expose a metrics port"
  delete_fixture svc-no-metrics-port.yaml
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
reset_events
case "${SCENARIO}" in
  healthy)              scenario_healthy ;;
  crashloop-pod)        scenario_crashloop_pod ;;
  replica-gap)          scenario_replica_gap ;;
  broken-webhook)       scenario_broken_webhook ;;
  url-webhook-no-ca)    scenario_url_webhook_no_ca ;;
  extra-crd-groups)     scenario_extra_crd_groups ;;
  warning-events)       scenario_warning_events ;;
  svc-no-endpoints)     scenario_svc_no_endpoints ;;
  svc-no-metrics-port)  scenario_svc_no_metrics_port ;;
  *)
    echo "Unknown scenario: ${SCENARIO}" >&2
    exit 2
    ;;
esac

log "PASS"
