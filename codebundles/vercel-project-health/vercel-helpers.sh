#!/usr/bin/env bash
# Bundle-private bash helpers for the Vercel Project Health codebundle.
#
# All Vercel REST API operations live in the shared Python keyword library
# at codecollection/libraries/Vercel/ (importable via `Library Vercel`,
# callable from bash via `vercel_py <subcommand>`).
#
# This file only contains things that are simpler/clearer in bash:
#   - artifact dir scoping
#   - lookback-window math
#   - jq aggregation filters used by the bucket scripts
#   - issue title / next-steps formatters
#   - vercel_py() which resolves PYTHONPATH and invokes `python3 -m Vercel`.

# ---------------------------------------------------------------------------
# Python invocation
# ---------------------------------------------------------------------------

vercel_py() {
  # Resolve PYTHONPATH so the Vercel package imports cleanly in dev tree and runner image.
  local pp
  if [[ -n "${RW_LIBRARIES_DIR:-}" ]] && [[ -d "${RW_LIBRARIES_DIR}/Vercel" ]]; then
    pp="${RW_LIBRARIES_DIR}"
  elif [[ -d "${SCRIPT_DIR:-}/../../libraries/Vercel" ]]; then
    pp="${SCRIPT_DIR}/../../libraries"
  elif [[ -d /home/runwhen/codecollection/libraries/Vercel ]]; then
    pp="/home/runwhen/codecollection/libraries"
  else
    echo "[vercel] cannot locate codecollection/libraries/Vercel" >&2
    return 1
  fi
  PYTHONPATH="${pp}${PYTHONPATH:+:${PYTHONPATH}}" python3 -m Vercel "$@"
}

# ---------------------------------------------------------------------------
# Artifacts
# ---------------------------------------------------------------------------

vercel_artifact_dir() {
  printf '%s' "${VERCEL_ARTIFACT_DIR:-.}"
}

vercel_artifact_prepare() {
  local d
  d="$(vercel_artifact_dir)"
  mkdir -p "$d"
}

vercel_token_value() {
  printf '%s' "${VERCEL_TOKEN:-${vercel_token:-}}"
}

# vercel_resolve_project_id_cached
# Echoes the canonical `prj_...` project id, resolving slugs/names if needed.
# Strategy (in order):
#   1) If $VERCEL_PROJECT_ID already starts with `prj_`, return it as-is.
#   2) Reuse the artifact-dir cache written by the project-config task
#      (`vercel_project_config.json::.id`) so we avoid a second API hit when
#      the runbook already resolved the slug.
#   3) Live `vercel_py resolve-project-id` lookup as a last resort.
# Returns 0 on success and prints the prj_... id to stdout. On failure it
# prints the original raw value and returns 1 so the caller can decide.
vercel_resolve_project_id_cached() {
  local raw="${VERCEL_PROJECT_ID:?vercel_resolve_project_id_cached: VERCEL_PROJECT_ID is required}"
  if [[ "$raw" == prj_* ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  local artifact_dir cfg cached
  artifact_dir="$(vercel_artifact_dir)"
  cfg="${artifact_dir}/vercel_project_config.json"
  if [[ -f "$cfg" ]]; then
    cached="$(jq -r '.id // empty' "$cfg" 2>/dev/null || true)"
    if [[ -n "$cached" && "$cached" == prj_* ]]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi
  local tmp live
  tmp="$(mktemp)"
  if vercel_py resolve-project-id --project-id "$raw" --out "$tmp" >/dev/null 2>&1; then
    live="$(jq -r '.id // empty' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    if [[ -n "$live" && "$live" == prj_* ]]; then
      printf '%s\n' "$live"
      return 0
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  printf '%s\n' "$raw"
  return 1
}

# vercel_resolve_owner_id_cached
# Echoes the project's `accountId` (team_... for team projects, user_... for
# personal). Required by the historical request-logs endpoint
# (https://vercel.com/api/logs/request-logs?projectId=...&ownerId=...).
#
# Strategy:
#   1) Reuse $VERCEL_OWNER_ID if explicitly set.
#   2) Read `accountId` from the artifact-dir cache written by the
#      project-config task (`vercel_project_config.json`).
#   3) Fall back to a live `vercel_py get-project` lookup.
# Returns 0 on success and prints the team_/user_ id to stdout. On failure
# it prints empty and returns 1 so the caller can decide how to surface it.
vercel_resolve_owner_id_cached() {
  if [[ -n "${VERCEL_OWNER_ID:-}" ]]; then
    printf '%s\n' "$VERCEL_OWNER_ID"
    return 0
  fi
  local artifact_dir cfg cached
  artifact_dir="$(vercel_artifact_dir)"
  cfg="${artifact_dir}/vercel_project_config.json"
  if [[ -f "$cfg" ]]; then
    cached="$(jq -r '.accountId // empty' "$cfg" 2>/dev/null || true)"
    if [[ -n "$cached" ]]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi
  local raw="${VERCEL_PROJECT_ID:-}"
  if [[ -z "$raw" ]]; then
    return 1
  fi
  local tmp live
  tmp="$(mktemp)"
  if vercel_py get-project --project-id "$raw" --out "$tmp" >/dev/null 2>&1; then
    live="$(jq -r '.accountId // empty' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    if [[ -n "$live" ]]; then
      printf '%s\n' "$live"
      return 0
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ---------------------------------------------------------------------------
# Time window
# ---------------------------------------------------------------------------

vercel_compute_window_ms() {
  local hours="${TIME_WINDOW_HOURS:-24}"
  WIN_END_MS=$(( $(date +%s) * 1000 ))
  WIN_START_MS=$(( WIN_END_MS - hours * 3600 * 1000 ))
  export WIN_START_MS WIN_END_MS
}

# ---------------------------------------------------------------------------
# Issue text formatters
# ---------------------------------------------------------------------------
# These read either:
#   - a stderr blob (e.g. captured from a failed `vercel_py resolve-project-id`)
#   - a structured JSON error object written via `--error-out`.
# Both are searched for "invalidToken" to decide whether the token is at fault.

vercel_resolve_issue_title() {
  local blob="$1" raw="$2"
  if printf '%s' "$blob" | grep -q 'invalidToken'; then
    printf 'Vercel API rejected token (invalidToken) for project `%s`' "$raw"
  else
    printf 'Cannot resolve Vercel project `%s`' "$raw"
  fi
}

vercel_resolve_issue_next_steps() {
  local blob="$1"
  if printf '%s' "$blob" | grep -q 'invalidToken'; then
    printf '%s' "Create a new token at https://vercel.com/account/tokens — enable Read access for your resources (Account / Team / Projects as applicable). Replace the vercel_token secret and re-run."
  else
    printf '%s' "Confirm VERCEL_TEAM_ID matches the owning team, the token can access this project, and the project name matches Vercel (slug lookup is case-insensitive)."
  fi
}

# ---------------------------------------------------------------------------
# jq aggregation filters
# ---------------------------------------------------------------------------
# Input: an array of normalized request-log rows
# {ts, code, path, method, source, domain, level, deployment_id, branch,
#  environment, duration_ms, cache, region, error_code}
# (the canonical shape produced by `vercel_py request-logs --normalize`).

# vercel_aggregate_status_bucket <bucket> [extra_codes_csv]
# Bucket ∈ {"4xx","5xx","other"}. For "other", extra_codes_csv is required.
# Input rows: see canonical shape above.
# Output rows include count, first/last seen timestamps, sample timestamps,
# unique domains and source breakdown — used in the consolidated report.
vercel_aggregate_status_bucket() {
  local bucket="$1"
  local extras="${2:-}"
  local filter
  case "$bucket" in
    4xx)
      filter='map(select(.code >= 400 and .code < 500))'
      ;;
    5xx)
      filter='map(select(.code >= 500 and .code < 600))'
      ;;
    other)
      filter='($codes | split(",") | map(tonumber? // empty)) as $list
              | map(select(.code as $c | $list | index($c) != null))'
      ;;
    *)
      echo "vercel_aggregate_status_bucket: unknown bucket '$bucket'" >&2
      return 1
      ;;
  esac
  jq -c --arg codes "$extras" "
    ${filter}
    | group_by([.code, .path, .method])
    | map({
        code: .[0].code,
        method: .[0].method,
        path: .[0].path,
        count: length,
        first_seen_ms: ([.[] | .ts] | min),
        last_seen_ms:  ([.[] | .ts] | max),
        sample_ts:     ([.[] | .ts] | sort | reverse | .[0:5]),
        domains:       ([.[] | .domain // empty | select(. != \"\")] | unique | .[0:5]),
        sources:       ([.[] | .source // empty | select(. != \"\")] | unique),
        levels:        ([.[] | .level  // empty | select(. != \"\")] | unique)
      })
    | sort_by(-.count)
  "
}

# ---------------------------------------------------------------------------
# Markdown report formatters (stdout payload for RW.Core.Add Pre To Report)
# ---------------------------------------------------------------------------

# Convert ms epoch to ISO-8601 UTC; "-" for 0/empty.
vercel_md_fmt_ms() {
  local ms="${1:-0}"
  if [[ "$ms" -gt 0 ]]; then
    date -u -d "@$(( ms / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "${ms}ms"
  else
    echo "-"
  fi
}

# Markdown table of aggregate rows. stdin: JSON array of rows from
# vercel_aggregate_status_bucket. Always emits a complete table or "no rows".
vercel_md_routes_table() {
  # Single-quoted bash already preserves backslashes literally, so jq must
  # see plain `"` (not `\"`) inside the script — escaping was causing
  # "INVALID_CHARACTER" errors on the join() inside \(...) interpolations.
  jq -r '
    def fmt_ts(ms): if (ms // 0) <= 0 then "-" else (ms / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")) end;
    if length == 0 then "_no rows_"
    else
      [
        "| Code | Method | Path | Count | Last seen (UTC) | Domains | Sources |",
        "| --- | --- | --- | ---: | --- | --- | --- |",
        ( .[] | "| \(.code) | \(.method) | `\(.path)` | \(.count) | \(fmt_ts(.last_seen_ms)) | \(.domains // [] | join(", ")) | \(.sources // [] | join(", ")) |" )
      ] | join("\n")
    end
  '
}

# Markdown rendering of an aggregate's .debug.json (per-deployment row counts +
# any per-deployment errors). stdin: contents of <out>.json.debug.json.
vercel_md_debug_block() {
  jq -r '
    def fmt(o):
      if (o.error // null) != null then "- `\(o.deployment_id)`: ERROR — \(o.error[:200])"
      else "- `\(o.deployment_id)`: \(o.normalized_rows // 0) normalized rows" end;
    if (.per_deployment // []) | length == 0 then ""
    else
      "Per-deployment scan:\n" + ((.per_deployment // []) | map(fmt(.)) | join("\n"))
    end
  '
}

# vercel_paths_summary_jq <min_count_threshold>
# Reads a merged aggregate file with shape {"4xx":[...], "5xx":[...], "other":[...]}
# and emits a top-routes summary used by the consolidated report.
vercel_paths_summary_jq() {
  local thr="${1:-5}"
  jq -c --argjson thr "$thr" '
    {
      buckets: {
        "4xx": (.["4xx"] // []),
        "5xx": (.["5xx"] // []),
        "other": (.["other"] // [])
      }
    }
    | .buckets as $b
    | {
        totals: {
          "4xx": ($b["4xx"] | map(.count) | add // 0),
          "5xx": ($b["5xx"] | map(.count) | add // 0),
          "other": ($b["other"] | map(.count) | add // 0)
        },
        top: (
          [($b["4xx"][], $b["5xx"][], $b["other"][])]
          | map(select(.count >= $thr))
          | sort_by(-.count)
          | .[0:25]
        ),
        threshold: $thr
      }
  '
}
