#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install the baseline stack for the autoscaling-health test harness:
#
#   1. Standalone KWOK controller so fake Node objects reach Ready. The
#      autoscaling checks inspect Nodes (NotReady, cordoned, etc.), so we
#      materialize them via KWOK rather than scheduling real workloads.
#   2. Vendored Karpenter CRDs: karpenter.sh NodePool + NodeClaim plus the
#      AWS karpenter.k8s.aws EC2NodeClass schema. We vendor the schemas
#      only - no controller is installed, so applied CRs sit inert and we
#      drive their .status via `kubectl patch --subresource=status`.
#   3. Fake-karpenter Deployment whose container writes only INFO logs, so
#      the log scanner finds zero matches until a scenario layers in a
#      noisier pod.
#
# Args:
#   $1 - kubectl context (required)
#   $2 - KWOK release version (default v0.7.0)
# ---------------------------------------------------------------------------
set -euo pipefail

CONTEXT="${1:?kubectl context required}"
KWOK_VERSION="${2:-v0.7.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Installing KWOK ${KWOK_VERSION} into ${CONTEXT}..."
kubectl --context "${CONTEXT}" apply \
  -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
kubectl --context "${CONTEXT}" apply \
  -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"
kubectl --context "${CONTEXT}" -n kube-system rollout status deploy/kwok-controller --timeout=90s

echo "Installing vendored Karpenter and AWS NodeClass CRDs..."
kubectl --context "${CONTEXT}" apply -f "${TEST_DIR}/kubernetes/crds/"

echo "Installing baseline fake-karpenter workload..."
kubectl --context "${CONTEXT}" apply -f "${TEST_DIR}/kubernetes/base/namespace.yaml"
kubectl --context "${CONTEXT}" apply -f "${TEST_DIR}/kubernetes/base/"

kubectl --context "${CONTEXT}" -n karpenter rollout status deploy/karpenter --timeout=120s
echo "Baseline install complete."
