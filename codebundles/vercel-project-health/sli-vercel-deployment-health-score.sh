#!/usr/bin/env bash
# SLI dimension: lightweight signals derived from a single GET /v9/projects/{id} call.
#
# Emits FIVE binary sub-scores in a single JSON payload:
#   - production_deployment_ready    : 1 if the newest production entry in
#                                      project.latestDeployments has readyState == READY.
#   - recent_deployment_failures_ok  : 1 if count(ERROR|CANCELED in latestDeployments)
#                                      is at or below SLI_MAX_RECENT_FAILED_DEPLOYMENTS.
#   - production_branch_matches      : 1 if EXPECTED_PRODUCTION_BRANCH is unset OR
#                                      project.link.productionBranch matches it.
#   - production_deployment_fresh    : 1 if the latest production deployment was
#                                      created within SLI_MAX_PRODUCTION_AGE_HOURS.
#                                      Catches "main is far ahead of prod, nobody noticed."
#   - production_alias_current       : 1 if project.targets.production.id matches the
#                                      newest READY production deployment in
#                                      latestDeployments. 0 means the alias points at
#                                      an older deployment than what's available
#                                      (rollback in progress, or new deploy not yet
#                                      aliased — both worth surfacing).
#
# Also surfaces the underlying details (counts, branch, age of latest prod, alias ids)
# so the Robot task can include them in the report without a second API call.
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

emit_zero() {
  jq -n --arg reason "$1" '
    {
      production_deployment_ready: 0,
      recent_deployment_failures_ok: 0,
      production_branch_matches: 1,
      production_deployment_fresh: 0,
      production_alias_current: 1,
      reason: $reason,
      details: {}
    }'
}

if [[ -z "$(vercel_token_value)" ]]; then
  emit_zero "vercel_token missing"
  exit 0
fi

raw_tmp="$(mktemp)"
err_tmp="$(mktemp)"
if ! vercel_py get-project --project-id "${VERCEL_PROJECT_ID}" \
        --error-out "$err_tmp" --out "$raw_tmp" 2>>"$err_tmp"; then
  blob="$(head -c 400 "$err_tmp")"
  emit_zero "get-project failed: ${blob}"
  rm -f "$raw_tmp" "$err_tmp"
  exit 0
fi
rm -f "$err_tmp"

threshold="${SLI_MAX_RECENT_FAILED_DEPLOYMENTS:-1}"
expected_branch="${EXPECTED_PRODUCTION_BRANCH:-}"
max_age_hours="${SLI_MAX_PRODUCTION_AGE_HOURS:-168}"  # default: 7 days

# All five sub-scores derived from the single project payload.
jq --arg expected "$expected_branch" \
   --argjson thr "$threshold" \
   --argjson max_age "$max_age_hours" '
  def num(x): (x // 0 | tonumber? // 0);

  (.latestDeployments // []) as $ld
  | ( $ld
      | map(select((.target // "preview") == "production"))
      | sort_by(- num(.createdAt))
      | .[0] // null
    ) as $latest_prod
  | ( $ld
      | map(select(
          (.target // "preview") == "production"
          and ((.readyState // .state // "") == "READY")
        ))
      | sort_by(- num(.createdAt))
      | .[0] // null
    ) as $newest_ready_prod
  | ( $ld
      | map(select((.readyState // .state // "") | IN("ERROR","CANCELED")))
      | length
    ) as $failed_count
  | (.link.productionBranch // null) as $prod_branch
  | (.targets.production // null) as $alias_target
  | (
      if $alias_target == null then null
      else ($alias_target.id // $alias_target.uid // null) end
    ) as $alias_id
  | (
      if $latest_prod == null then 0
      elif ($latest_prod.readyState // $latest_prod.state // "") == "READY" then 1
      else 0 end
    ) as $prod_ready
  | (if $failed_count <= $thr then 1 else 0 end) as $failures_ok
  | (
      if ($expected // "") == "" then 1
      elif ($prod_branch // "") == $expected then 1
      else 0 end
    ) as $branch_ok
  | (
      if $latest_prod == null then null
      else (
        ((now * 1000) - num($latest_prod.createdAt)) / 1000.0 / 3600.0
        | (. * 100 | floor) / 100
      )
      end
    ) as $age_hours
  | (
      # Fresh = latest production deployment within max_age_hours.
      # Score 1 (no penalty) when we cannot determine an age — avoids penalizing
      # brand-new projects that have no production yet (prod_ready already covers that).
      if $age_hours == null then 1
      elif $age_hours <= $max_age then 1
      else 0 end
    ) as $prod_fresh
  | (
      # Alias current = the alias target id matches the newest READY production deployment.
      # Score 1 when:
      #   - the project payload does not expose targets.production (older API shape), or
      #   - there is no READY production yet (prod_ready already covers that), or
      #   - the alias target id matches the newest READY production.
      # Score 0 when both are present and they differ — i.e., a rollback or
      # the latest deploy has not aliased yet (worth surfacing either way).
      if $alias_id == null then 1
      elif $newest_ready_prod == null then 1
      elif ($newest_ready_prod.uid // $newest_ready_prod.id) == $alias_id then 1
      else 0 end
    ) as $alias_current
  | {
      production_deployment_ready: $prod_ready,
      recent_deployment_failures_ok: $failures_ok,
      production_branch_matches: $branch_ok,
      production_deployment_fresh: $prod_fresh,
      production_alias_current: $alias_current,
      details: {
        latest_production_uid: ($latest_prod.uid // $latest_prod.id // null),
        latest_production_state: ($latest_prod.readyState // $latest_prod.state // null),
        latest_production_url: ($latest_prod.url // null),
        latest_production_age_hours: $age_hours,
        max_production_age_hours: $max_age,
        recent_deployments_inspected: ($ld | length),
        recent_failed_count: $failed_count,
        recent_failed_threshold: $thr,
        production_branch: $prod_branch,
        expected_production_branch: ($expected // null),
        alias_deployment_id: $alias_id,
        newest_ready_production_id: ($newest_ready_prod.uid // $newest_ready_prod.id // null),
        newest_ready_production_url: ($newest_ready_prod.url // null)
      }
    }
' "$raw_tmp"
rm -f "$raw_tmp"
