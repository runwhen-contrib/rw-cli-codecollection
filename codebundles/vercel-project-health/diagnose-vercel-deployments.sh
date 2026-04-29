#!/usr/bin/env bash
# Standalone diagnostic for the Vercel deployments fetch path. Exercises the
# same Python CLI (`python -m Vercel`) the bundle scripts use, so failures here
# match what the runbook will see.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
TOKEN="$(vercel_token_value)"
: "${TOKEN:?Must set VERCEL_TOKEN or vercel_token secret}"

attempts="${VERCEL_DIAG_ATTEMPTS:-3}"
limit="${VERCEL_DIAG_LIMIT:-20}"

echo "[diagnose] VERCEL_PROJECT_ID=${VERCEL_PROJECT_ID} VERCEL_TEAM_ID=${VERCEL_TEAM_ID:-<unset>}"

resolved="$(mktemp)"
err="$(mktemp)"
if ! vercel_py resolve-project-id \
      --project-id "$VERCEL_PROJECT_ID" \
      --error-out "$err" \
      --out "$resolved" 2>>"$err"; then
  echo "[diagnose] resolve-project-id failed:"
  cat "$err"
  rm -f "$resolved" "$err"
  exit 1
fi
PROJECT_ID="$(jq -r '.id // empty' "$resolved")"
PROJECT_NAME="$(jq -r '.name // empty' "$resolved")"
RESOLVED_FROM="$(jq -r '.resolved_from // empty' "$resolved")"
rm -f "$resolved" "$err"
echo "[diagnose] resolved id=${PROJECT_ID} name=${PROJECT_NAME} via=${RESOLVED_FROM}"

for i in $(seq 1 "$attempts"); do
  echo "----- list-deployments attempt ${i}/${attempts} -----"
  body="$(mktemp)"
  err="$(mktemp)"
  if vercel_py list-deployments \
        --project-id "$PROJECT_ID" \
        --page-limit "$limit" \
        --max-pages 1 \
        --error-out "$err" \
        --out "$body" 2>>"$err"; then
    count="$(jq -r '.deployments | length' "$body" 2>/dev/null || echo 0)"
    echo "list-deployments OK (deployments: ${count})"
    if [[ "${count:-0}" -gt 0 ]]; then
      echo "first uid: $(jq -r '.deployments[0].uid // "<none>"' "$body")"
    fi
    rm -f "$body" "$err"
    echo "[diagnose] success on attempt ${i}"
    exit 0
  fi
  echo "list-deployments FAILED:"
  cat "$err" || true
  rm -f "$body" "$err"
done
echo "[diagnose] all attempts exhausted"
exit 1
