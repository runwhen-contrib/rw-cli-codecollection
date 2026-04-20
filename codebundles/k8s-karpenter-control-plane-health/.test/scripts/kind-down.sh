#!/usr/bin/env bash
set -euo pipefail

NAME="${1:?kind cluster name required}"

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is not installed; nothing to delete."
  exit 0
fi

if kind get clusters 2>/dev/null | grep -qx "${NAME}"; then
  echo "Deleting Kind cluster '${NAME}'..."
  kind delete cluster --name "${NAME}"
else
  echo "Kind cluster '${NAME}' not found; nothing to delete."
fi
