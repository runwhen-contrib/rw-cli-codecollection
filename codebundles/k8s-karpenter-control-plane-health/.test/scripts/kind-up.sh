#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create (or reuse) the ephemeral Kind cluster that backs this bundle's
# .test harness. Idempotent: re-running when the cluster already exists is
# a no-op.
#
# Args:
#   $1 - Kind cluster name (required)
# ---------------------------------------------------------------------------
set -euo pipefail

NAME="${1:?kind cluster name required}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.0}"

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is not installed. Install from https://kind.sigs.k8s.io/docs/user/quick-start/#installation" >&2
  exit 2
fi

if kind get clusters 2>/dev/null | grep -qx "${NAME}"; then
  echo "Kind cluster '${NAME}' already exists; reusing."
  exit 0
fi

echo "Creating Kind cluster '${NAME}' (image=${KIND_NODE_IMAGE})..."
kind create cluster --name "${NAME}" --image "${KIND_NODE_IMAGE}" --wait 90s
echo "Kind cluster '${NAME}' ready. kubectl context: kind-${NAME}"
