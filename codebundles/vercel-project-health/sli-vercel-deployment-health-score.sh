#!/usr/bin/env bash
# SLI dimension: lightweight signals derived from a single GET /v9/projects/{id}
# call already performed by the calling Robot task via the `Get Vercel Project`
# keyword. This script only computes the five binary sub-scores from the
# project JSON file (path supplied via VERCEL_PROJECT_JSON_PATH).
#
# Source of truth for "the live production deployment" is
# project.targets.production (the deployment the production alias points at);
# project.latestDeployments is only consulted as a fallback and to detect
# alias drift / count recent failures, because it is unreliable for projects
# whose recent activity is mostly preview deployments.
#
# Emits FIVE binary sub-scores in a single JSON payload:
#   - production_deployment_ready    : 1 if project.targets.production has
#                                      readyState == READY (live alias points
#                                      at a healthy deployment).
#   - recent_deployment_failures_ok  : 1 if count(ERROR|CANCELED in
#                                      latestDeployments) is at or below
#                                      SLI_MAX_RECENT_FAILED_DEPLOYMENTS.
#   - production_branch_matches      : 1 if EXPECTED_PRODUCTION_BRANCH is
#                                      unset OR project.link.productionBranch
#                                      matches it.
#   - production_deployment_fresh    : 1 if the live production deployment
#                                      was created within
#                                      SLI_MAX_PRODUCTION_AGE_HOURS. Catches
#                                      "main is far ahead of prod, nobody
#                                      noticed." Scores 0 (not 1) when the
#                                      alias is set but we cannot determine
#                                      its age — that is a blind spot, not a
#                                      pass.
#   - production_alias_current       : 1 if project.targets.production.id
#                                      matches the newest READY production
#                                      deployment seen across
#                                      project.targets.production +
#                                      latestDeployments. 0 means the alias
#                                      points at an older deployment than
#                                      what is available (rollback in
#                                      progress, or new deploy not yet
#                                      aliased — both worth surfacing).
#
# Also surfaces the underlying details (counts, branch, age of latest prod,
# alias ids) so the Robot task can include them in the report.
set -uo pipefail

: "${VERCEL_PROJECT_JSON_PATH:?Must set VERCEL_PROJECT_JSON_PATH (path to GET /v9/projects/{id} response JSON)}"

if [[ ! -s "$VERCEL_PROJECT_JSON_PATH" ]]; then
  jq -n '{
    production_deployment_ready: 0,
    recent_deployment_failures_ok: 0,
    production_branch_matches: 1,
    production_deployment_fresh: 1,
    production_alias_current: 1,
    reason: "missing or empty project JSON",
    details: {}
  }'
  exit 0
fi

threshold="${SLI_MAX_RECENT_FAILED_DEPLOYMENTS:-1}"
expected_branch="${EXPECTED_PRODUCTION_BRANCH:-}"
max_age_hours="${SLI_MAX_PRODUCTION_AGE_HOURS:-168}"  # default: 7 days

jq --arg expected "$expected_branch" \
   --argjson thr "$threshold" \
   --argjson max_age "$max_age_hours" '
  def num(x): (x // 0 | tonumber? // 0);
  def is_ready(d): ((d.readyState // d.state // "") == "READY");

  (.latestDeployments // []) as $ld
  | (.targets.production // null) as $prod_target
  | (
      if $prod_target == null then null
      else ($prod_target.id // $prod_target.uid // null) end
    ) as $alias_id

  # Production deployments seen in latestDeployments, newest first.
  | ( $ld
      | map(select((.target // "preview") == "production"))
      | sort_by(- num(.createdAt))
    ) as $prod_history

  # Live production = whatever the alias points at (project.targets.production),
  # falling back to the newest production entry in latestDeployments only
  # when the alias has never been set.
  | ( $prod_target // ($prod_history[0] // null) ) as $latest_prod

  # Newest READY production across BOTH sources (alias target +
  # latestDeployments), sorted by createdAt. We need the genuinely newest
  # READY deployment so we can compare against the alias target id and
  # detect drift (alias points at an older deployment than what is
  # available, i.e. a rollback or a deploy-without-promote in progress).
  | (
      ( $prod_history | map(select(is_ready(.))) ) as $ready_history
      | (
          if $prod_target != null and is_ready($prod_target)
          then [ $prod_target ] + $ready_history
          else $ready_history
          end
        )
      | sort_by(- num(.createdAt))
      | .[0] // null
    ) as $newest_ready_prod

  | ( $ld
      | map(select((.readyState // .state // "") | IN("ERROR","CANCELED")))
      | length
    ) as $failed_count
  | (.link.productionBranch // null) as $prod_branch

  # prod_ready: alias points at a deployment whose readyState is READY.
  # Score 0 when there is no live production yet OR the alias target is
  # not READY (building / errored / canceled).
  | (
      if $latest_prod == null then 0
      elif is_ready($latest_prod) then 1
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
      elif num($latest_prod.createdAt) == 0 then null
      else (
        ((now * 1000) - num($latest_prod.createdAt)) / 1000.0 / 3600.0
        | (. * 100 | floor) / 100
      )
      end
    ) as $age_hours

  | (
      # Fresh = live production deployment within max_age_hours.
      # If no production exists at all (alias unset and history empty),
      # score 1 — nothing to be stale about (prod_ready already covers it).
      # If the alias IS set but we somehow cannot read its createdAt,
      # score 0: that is a measurement blind spot, not a pass.
      if $latest_prod == null then 1
      elif $age_hours == null then 0
      elif $age_hours <= $max_age then 1
      else 0 end
    ) as $prod_fresh

  | (
      # Alias current = the alias target id matches the newest READY
      # production deployment we can see.
      #   - alias unset → 1 (nothing aliased; prod_ready covers it)
      #   - alias set + we can see a READY production:
      #       match → 1, mismatch → 0 (rollback or pending alias)
      #   - alias set but we cannot find ANY READY production
      #     (alias target itself is not READY and history has none) → 0:
      #     production is broken or invisible to us, not healthy.
      if $alias_id == null then 1
      elif $newest_ready_prod == null then 0
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
        latest_production_source: (
          if $prod_target != null then "targets.production"
          elif ($prod_history | length) > 0 then "latestDeployments"
          else "(none)" end
        ),
        latest_production_age_hours: $age_hours,
        max_production_age_hours: $max_age,
        recent_deployments_inspected: ($ld | length),
        recent_production_history_size: ($prod_history | length),
        recent_failed_count: $failed_count,
        recent_failed_threshold: $thr,
        production_branch: $prod_branch,
        expected_production_branch: ($expected // null),
        alias_deployment_id: $alias_id,
        newest_ready_production_id: ($newest_ready_prod.uid // $newest_ready_prod.id // null),
        newest_ready_production_url: ($newest_ready_prod.url // null)
      }
    }
' "$VERCEL_PROJECT_JSON_PATH"
