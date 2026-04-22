#!/usr/bin/env bash
# Merge per-bucket aggregates, apply thresholds, emit summary JSON and issue list.
set -euo pipefail
set -x

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"

SUMMARY_JSON="vercel_http_error_summary.json"
ISSUES_FILE="vercel_http_error_report_issues.json"
threshold="${MIN_REQUEST_COUNT_THRESHOLD:-5}"

load_or_empty() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo '{"paths":[]}'
  fi
}

j404="$(load_or_empty vercel_aggregate_404.json)"
j5="$(load_or_empty vercel_aggregate_5xx.json)"
jo="$(load_or_empty vercel_aggregate_other.json)"

table="$(jq -n -r --argjson j404 "$j404" --argjson j5 "$j5" --argjson jo "$jo" '
  def rows($b; $doc):
    ($doc.paths // []) | map(. + {bucket: $b});
  ([rows("404"; $j404), rows("5xx"; $j5), rows("other"; $jo)]
  | add // []
  | sort_by(-.count)
  | .[0:25]) as $r
  | if ($r | length) == 0 then "(no error paths in window)"
    else
      [ (["PATH", "METHOD", "BUCKET", "COUNT", "SAMPLE_TS"] | @tsv),
        ($r[] | [.path, .method, .bucket, (.count | tostring), (.sample_ts | tostring)] | @tsv)
      ] | join("\n")
    end
')"

jq -n \
  --argjson j404 "$j404" \
  --argjson j5 "$j5" \
  --argjson jo "$jo" \
  --argjson th "$threshold" \
  --arg tbl "$table" \
  --arg pid "$VERCEL_PROJECT_ID" \
  '{
    project_id: $pid,
    min_request_threshold: $th,
    buckets: { "404": $j404, "5xx": $j5, "other": $jo },
    top_routes_table: $tbl
  }' >"$SUMMARY_JSON"

issues_json="$(jq -n -c \
  --argjson j404 "$j404" \
  --argjson j5 "$j5" \
  --argjson jo "$jo" \
  --argjson th "$threshold" \
  --arg tbl "$table" \
  --arg pid "$VERCEL_PROJECT_ID" \
  '
  def rows($b; $doc):
    ($doc.paths // []) | map(. + {bucket: $b});
  def allp:
    [rows("404"; $j404), rows("5xx"; $j5), rows("other"; $jo)] | add // [];
  def mx5h: ([ allp[] | select(.bucket == "5xx" and .count >= $th) ] | length) > 0;
  def mx5a: ([ allp[] | select(.bucket == "5xx" and .count >= 1) ] | length) > 0;
  def mx4h: ([ allp[] | select(.bucket == "404" and .count >= $th) ] | length) > 0;
  def mxoh: ([ allp[] | select(.bucket == "other" and .count >= $th) ] | length) > 0;
  def anyerr: ([allp[] | select(.count >= 1)] | length) > 0;
  if (anyerr | not) then []
  else
    (if mx5h then 4
     elif mx5a or mx4h or mxoh then 3
     else 2 end) as $sev
    | [{
        title: ("Vercel HTTP errors aggregated for project `" + $pid + "`"),
        details: ("Threshold=" + ($th | tostring) + " requests/path for high-severity noise reduction.\n\nTop routes:\n" + $tbl),
        severity: $sev,
        next_steps: "Review routes in Vercel dashboard logs, fix broken links or handlers, validate rewrites/middleware, and redeploy. Cross-check deployment targets vs DEPLOYMENT_ENVIRONMENT."
      }]
  end
')"

echo "$issues_json" >"$ISSUES_FILE"
echo "Wrote ${SUMMARY_JSON} and ${ISSUES_FILE}"
