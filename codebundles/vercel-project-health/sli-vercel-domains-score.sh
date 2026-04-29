#!/usr/bin/env bash
# SLI dimension: every production-bound domain on the project is verified.
#
# Calls GET /v9/projects/{id}/domains once and emits a single JSON object:
#   {
#     domains_verified_ok: 0|1,
#     details: {
#       production_domains: <count>,
#       verified: <count>,
#       unverified: [{name, apexName}, ...]
#     },
#     reason: "" | "vercel_token-missing" | "api-error"
#   }
#
# A domain is "production-bound" when it has no `gitBranch` (preview alias) and
# no `customEnvironmentId` (custom-environment alias). Auto-generated
# *.vercel.app aliases are always verified by Vercel, so they don't drag the
# score down.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

emit() {
  jq -n \
    --argjson score "${1:-0}" \
    --arg reason "${2:-}" \
    --argjson details "${3:-null}" \
    '{
       domains_verified_ok: $score,
       reason: ($reason // ""),
       details: ($details // {})
     }'
}

if [[ -z "$(vercel_token_value)" ]]; then
  emit 0 "vercel_token-missing"
  exit 0
fi

PROJECT_RAW="${VERCEL_PROJECT_ID:?VERCEL_PROJECT_ID required}"
PROJECT_ID="$(vercel_resolve_project_id_cached)" || PROJECT_ID="$PROJECT_RAW"

raw_tmp="$(mktemp)"
err_tmp="$(mktemp)"
trap 'rm -f "$raw_tmp" "$err_tmp" 2>/dev/null || true' EXIT

if ! vercel_py list-project-domains \
       --project-id "$PROJECT_ID" \
       --production-only \
       --error-out "$err_tmp" \
       --out "$raw_tmp" 2>>"$err_tmp"; then
  blob="$(head -c 400 "$err_tmp" | sed 's/[[:cntrl:]]//g')"
  emit 0 "api-error" "$(jq -n --arg b "$blob" '{error: $b}')"
  exit 0
fi

# Domains with verified=true (or no `verification` array) are healthy. Anything
# explicitly verified=false drops the score.
jq '
  ( . // [] ) as $domains
  | ( $domains | map(select(.verified != false)) | length ) as $verified
  | ( $domains | map(select(.verified == false)) ) as $unverified
  | {
      domains_verified_ok: (
        if ($domains | length) == 0 then 1                # nothing to verify → not penalized
        elif ($unverified | length) == 0 then 1
        else 0 end
      ),
      reason: "",
      details: {
        production_domains: ($domains | length),
        verified: $verified,
        unverified: (
          $unverified | map({
            name: .name,
            apexName: (.apexName // null),
            redirect: (.redirect // null),
            verification: (.verification // [])
          })
        )
      }
    }
' "$raw_tmp"
