#!/usr/bin/env bash
set -euo pipefail
# Static validation for the CodeBundle (no live Elasticsearch required).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "Validating shell scripts under ${ROOT}"
for f in "${ROOT}"/*.sh; do
  if [[ -f "${f}" ]]; then
    bash -n "${f}"
    echo "OK ${f}"
  fi
done
echo "All shell scripts passed bash -n."
