#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install the healthy-baseline stack into the test cluster:
#   1. Standalone KWOK controller (so fake Nodes reach Ready). The
#      control-plane-health bundle does not itself need fake nodes, but
#      keeping KWOK in the baseline makes this script identical in shape
#      to the autoscaling-health bundle's install and leaves room for
#      future scenarios.
#   2. Vendored Karpenter NodePool CRD (so the CRD-group check finds the
#      expected karpenter.sh group).
#   3. Fake-karpenter workload: namespace, Deployment, Service, and healthy
#      Validating/Mutating webhook configurations.
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

echo "Installing vendored Karpenter CRDs..."
kubectl --context "${CONTEXT}" apply -f "${TEST_DIR}/kubernetes/crds/"

echo "Installing baseline fake-karpenter workload..."
# Namespace first so the subsequent apply succeeds even if kubectl's
# directory-ordered apply processes Deployment/Service before Namespace.
kubectl --context "${CONTEXT}" apply -f "${TEST_DIR}/kubernetes/base/namespace.yaml"
kubectl --context "${CONTEXT}" apply -f "${TEST_DIR}/kubernetes/base/"

echo "Waiting for fake-karpenter Deployment to become ready..."
kubectl --context "${CONTEXT}" -n karpenter rollout status deploy/karpenter --timeout=120s

echo "Baseline install complete."
