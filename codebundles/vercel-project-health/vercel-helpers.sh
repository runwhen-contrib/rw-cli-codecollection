#!/usr/bin/env bash
# Bundle-private bash helpers for the Vercel Project Health codebundle.
#
# All Vercel REST API operations are performed by Robot tasks via the shared
# `Vercel` Python keyword library at codecollection/libraries/Vercel/
# (declared with `Library    Vercel` in runbook.robot / sli.robot). The Robot
# tasks call keywords like `Get Vercel Project`, `List Vercel Deployments`,
# `Fetch Vercel Request Logs` and pass the result to bash via `out_path` /
# environment variables. Bash scripts in this bundle DO NOT call the Vercel
# REST API directly — they only do jq aggregation, markdown rendering, and
# issue-file generation.
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
  # The codecollection's Python libraries (libraries/Vercel/) are auto-installed
  # onto PYTHONPATH by the RunWhen runner image, AND surfaced into the Robot
  # process by `Library    Vercel` in runbook.robot / sli.robot. Once Robot has
  # loaded the library, every bash subprocess invoked via RW.CLI.Run Bash File
  # can import it directly — `python3 -m Vercel <subcmd>` Just Works.
  #
  # In the dev tree (e.g. running `ro` from a codespace), the lib is also
  # importable because task setup symlinks the codecollection into
  # /home/runwhen/codecollection which is on the runner image's PYTHONPATH.
  #
  # If neither path is in effect, fall back to two well-known dev-tree
  # locations and emit a one-line diagnostic so failures aren't opaque.
  if python3 -c 'import Vercel' >/dev/null 2>&1; then
    python3 -m Vercel "$@"
    return $?
  fi

  local helpers_src script_src candidate
  helpers_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  script_src="${SCRIPT_DIR:-$helpers_src}"
  for candidate in \
      "${RW_LIBRARIES_DIR:-}" \
      "${script_src}/../../libraries" \
      "${helpers_src}/../../libraries" \
      "/home/runwhen/codecollection/libraries"; do
    [[ -z "$candidate" ]] && continue
    if [[ -d "${candidate}/Vercel" ]]; then
      PYTHONPATH="${candidate}${PYTHONPATH:+:${PYTHONPATH}}" python3 -m Vercel "$@"
      return $?
    fi
  done

  echo "[vercel] cannot import Vercel package: not on PYTHONPATH and no dev-tree fallback found. Ensure 'Library    Vercel' is declared in the calling .robot file." >&2
  return 1
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
# jq aggregation filters
# ---------------------------------------------------------------------------
# Input: an array of normalized request-log rows
# {ts, code, path, method, source, domain, level, deployment_id, branch,
#  environment, duration_ms, cache, region, error_code}
# (the canonical shape produced by the Vercel keyword
# `Normalize Vercel Request Log Rows`).

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
