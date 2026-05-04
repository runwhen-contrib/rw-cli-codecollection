#!/usr/bin/env bash
set -euo pipefail
# Static validation only — MongoDB Atlas test projects require customer-provided org/project credentials.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
while IFS= read -r -d '' f; do
  if ! bash -n "$f"; then
    echo "bash -n failed: $f" >&2
    failed=1
  fi
done < <(find "$ROOT" -maxdepth 1 -name '*.sh' -print0)
exit "$failed"
