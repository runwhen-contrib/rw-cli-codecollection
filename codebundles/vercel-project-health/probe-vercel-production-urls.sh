#!/usr/bin/env bash
# Probe a configurable set of paths against the project's production URL using
# real HTTP GETs and aggregate the response codes by path. Replaces the previous
# runtime-logs streaming approach: Vercel's /v1/runtime-logs is live-tail only
# (no historical query), so a synthetic probe is the only way to get HTTP-error
# signal for free-plan projects without setting up Log Drains.
#
# Output:
#   ${ARTIFACT_DIR}/vercel_synthetic_probe.json         — {base_url, paths:[{path,code,latency_ms,ok,attempts,error?}], meta}
#   ${ARTIFACT_DIR}/vercel_synthetic_probe_issues.json  — Robot issues array
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
OUT_JSON="${ARTIFACT_DIR}/vercel_synthetic_probe.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_synthetic_probe_issues.json"
echo '[]' >"$ISSUES_FILE"
echo '{"paths":[]}' >"$OUT_JSON"

paths_csv="${VERCEL_PROBE_PATHS:-/}"
timeout_s="${VERCEL_PROBE_TIMEOUT_SECONDS:-10}"
ua="${VERCEL_PROBE_USER_AGENT:-runwhen-vercel-health/1.0}"
success_csv="${VERCEL_PROBE_SUCCESS_CODES:-200,201,204,301,302,303,304,307,308}"
slow_ms="${VERCEL_PROBE_SLOW_MS:-2000}"
threshold_high="${MIN_REQUEST_COUNT_THRESHOLD:-5}"

# ---------------------------------------------------------------------------
# Resolve the base URL
# ---------------------------------------------------------------------------
BASE_URL="${VERCEL_PROBE_BASE_URL:-}"
base_source="env"
if [[ -z "$BASE_URL" ]]; then
  cfg="${ARTIFACT_DIR}/vercel_project_config.json"
  if [[ -f "$cfg" ]]; then
    # Prefer a custom production alias (the user's domain) over the auto
    # *.vercel.app alias from the latest deployment.
    custom="$(jq -r '
      .alias // []
      | map(select(type=="string"))
      | map(select(endswith(".vercel.app") | not))
      | .[0] // empty
    ' "$cfg" 2>/dev/null || true)"
    if [[ -n "$custom" ]]; then
      BASE_URL="https://${custom}"
      base_source="project-config:custom-alias"
    else
      latest_url="$(jq -r '
        ((.latestDeployments // [])
         | map(select((.target // "preview") == "production"))
         | sort_by(- (.createdAt // 0))
         | .[0].url
        ) // empty
      ' "$cfg" 2>/dev/null || true)"
      if [[ -n "$latest_url" && "$latest_url" != "null" ]]; then
        BASE_URL="https://${latest_url}"
        base_source="project-config:latest-production-deployment"
      fi
    fi
  fi
fi

if [[ -z "$BASE_URL" ]]; then
  jq -n --arg t "Cannot determine probe base URL for \`${VERCEL_PROJECT_ID}\`" \
        --arg d "VERCEL_PROBE_BASE_URL is unset and vercel_project_config.json had neither a custom alias nor a production deployment URL. Run the project-config task first or pass VERCEL_PROBE_BASE_URL explicitly." \
        --arg n "Set VERCEL_PROBE_BASE_URL=https://<your-production-domain> in the bundle config, or ensure the project-config task ran successfully." \
        --argjson sev 4 \
        '[{title:$t, details:$d, severity:$sev, next_steps:$n}]' >"$ISSUES_FILE"
  printf '### Synthetic probe — %s\n\n' "$VERCEL_PROJECT_ID"
  echo "Cannot probe — no base URL available."
  exit 0
fi

# Strip trailing / from base url so concat with paths is consistent.
BASE_URL="${BASE_URL%/}"

# ---------------------------------------------------------------------------
# Probe loop
# ---------------------------------------------------------------------------
results_jsonl="$(mktemp)"
: >"$results_jsonl"

# Splits paths_csv on ',', trims whitespace.
IFS=',' read -r -a paths_array <<<"$paths_csv"
probe_started_ms=$(( $(date +%s) * 1000 ))

for raw_path in "${paths_array[@]}"; do
  path="$(printf '%s' "$raw_path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$path" ]] && continue
  # Ensure path starts with /
  [[ "$path" != /* ]] && path="/$path"
  url="${BASE_URL}${path}"
  start_ns=$(date +%s%N)
  # %{http_code} %{time_total} %{size_download} %{num_redirects} %{url_effective}
  curl_out="$(
    curl -sS -L --max-time "$timeout_s" \
      -H "User-Agent: ${ua}" \
      -H "Accept: */*" \
      -o /dev/null \
      -w '%{http_code}|%{time_total}|%{size_download}|%{num_redirects}|%{url_effective}' \
      "$url" 2>&1 || true
  )"
  curl_rc=$?
  end_ns=$(date +%s%N)
  total_ms=$(( (end_ns - start_ns) / 1000000 ))

  http_code="0"
  time_total="0"
  size_download="0"
  num_redirects="0"
  url_effective="$url"
  err_text=""
  if [[ "$curl_out" =~ ^[0-9]+\| ]]; then
    IFS='|' read -r http_code time_total size_download num_redirects url_effective <<<"$curl_out"
  else
    err_text="$curl_out"
  fi

  jq -c -n \
    --arg method "GET" \
    --arg path "$path" \
    --arg url "$url" \
    --arg url_effective "$url_effective" \
    --arg err "$err_text" \
    --arg success_csv "$success_csv" \
    --argjson code "${http_code:-0}" \
    --argjson redirects "${num_redirects:-0}" \
    --argjson size "${size_download:-0}" \
    --argjson rc "${curl_rc:-0}" \
    --argjson latency_ms "$total_ms" \
    '
    ($success_csv | split(",") | map(tonumber? // empty)) as $ok_codes
    | {
        method: $method,
        path: $path,
        url: $url,
        url_effective: $url_effective,
        code: $code,
        latency_ms: $latency_ms,
        size_bytes: $size,
        redirects: $redirects,
        curl_rc: $rc,
        ok: ($code as $c | ($ok_codes | index($c) != null)),
        bucket: (
          if $code == 0 then "error"
          elif $code >= 500 then "5xx"
          elif $code >= 400 then "4xx"
          else "ok" end
        ),
        error: ($err | select(. != ""))
      }' >>"$results_jsonl"
done

probe_completed_ms=$(( $(date +%s) * 1000 ))

# ---------------------------------------------------------------------------
# Build aggregate JSON
# ---------------------------------------------------------------------------
results_json="$(jq -s '.' "$results_jsonl")"
rm -f "$results_jsonl"

jq -n \
  --arg pid "$VERCEL_PROJECT_ID" \
  --arg base "$BASE_URL" \
  --arg base_source "$base_source" \
  --argjson started "$probe_started_ms" \
  --argjson completed "$probe_completed_ms" \
  --argjson results "$results_json" \
  --argjson timeout "$timeout_s" \
  --arg ua "$ua" \
  --arg success_csv "$success_csv" \
  --argjson slow_ms "$slow_ms" \
  '{
    project_id: $pid,
    base_url: $base,
    base_url_source: $base_source,
    started_ms: $started,
    completed_ms: $completed,
    timeout_seconds: $timeout,
    user_agent: $ua,
    success_codes: ($success_csv | split(",") | map(tonumber? // empty)),
    slow_threshold_ms: $slow_ms,
    paths: $results,
    totals: {
      probed:   ($results | length),
      ok:       ([$results[] | select(.bucket == "ok")] | length),
      "4xx":    ([$results[] | select(.bucket == "4xx")] | length),
      "5xx":    ([$results[] | select(.bucket == "5xx")] | length),
      error:    ([$results[] | select(.bucket == "error")] | length),
      slow_ok:  ([$results[] | select(.bucket == "ok" and .latency_ms > $slow_ms)] | length)
    }
  }' >"$OUT_JSON"

# ---------------------------------------------------------------------------
# Build issues
# ---------------------------------------------------------------------------
issues_json="$(jq -c -n \
  --argjson doc "$(cat "$OUT_JSON")" \
  --arg pid "$VERCEL_PROJECT_ID" \
  --argjson th "$threshold_high" '
  def fmt_path($r): "HTTP \($r.code) \($r.method) `\($r.path)` (\($r.latency_ms)ms)";
  ( [$doc.paths[] | select(.bucket == "5xx")] ) as $five
  | ( [$doc.paths[] | select(.bucket == "4xx")] ) as $four
  | ( [$doc.paths[] | select(.bucket == "error")] ) as $err
  | ( [$doc.paths[] | select(.bucket == "ok" and .latency_ms > $doc.slow_threshold_ms)] ) as $slow
  | (
      ( if ($five | length) > 0 then
          [{
            severity: 4,
            title: ("Vercel synthetic probe: 5xx responses on `" + $pid + "`"),
            details: ("Probe against " + $doc.base_url + " saw " + (($five|length)|tostring) + " path(s) returning 5xx:\n" + ($five | map("- " + fmt_path(.)) | join("\n"))),
            next_steps: "Check the latest production deployment in the Vercel dashboard (Functions / Edge Functions logs). 5xx responses indicate a runtime failure on the server side."
          }]
        else [] end )
      +
      ( if ($err | length) > 0 then
          [{
            severity: 4,
            title: ("Vercel synthetic probe: requests failed entirely on `" + $pid + "`"),
            details: ("Probe against " + $doc.base_url + " could not get a response from " + (($err|length)|tostring) + " path(s) — DNS, TLS, or connection failure. Paths: " + ($err | map(.path) | join(", "))),
            next_steps: "Verify the production URL is correct and reachable. If the project just deployed, the alias may not be ready yet. Override with VERCEL_PROBE_BASE_URL if your custom domain differs from the auto alias."
          }]
        else [] end )
      +
      ( if ($four | length) > 0 then
          [{
            severity: (if ($four|length) >= $th then 3 else 2 end),
            title: ("Vercel synthetic probe: 4xx responses on `" + $pid + "`"),
            details: ("Probe against " + $doc.base_url + " saw " + (($four|length)|tostring) + " path(s) returning 4xx:\n" + ($four | map("- " + fmt_path(.)) | join("\n"))),
            next_steps: "401/403 typically indicate auth/middleware issues; 404 indicates routing/rewrite gaps; 422 indicates request validation. Verify the path list (VERCEL_PROBE_PATHS) matches deployed routes and that public endpoints are not behind auth."
          }]
        else [] end )
      +
      ( if ($slow | length) > 0 then
          [{
            severity: 2,
            title: ("Vercel synthetic probe: slow responses on `" + $pid + "`"),
            details: ("Probe saw " + (($slow|length)|tostring) + " path(s) returning OK but above " + ($doc.slow_threshold_ms|tostring) + "ms:\n" + ($slow | map("- " + fmt_path(.)) | join("\n"))),
            next_steps: "Cold-start latency can produce single-shot slow responses; rerun to see if it persists. If it persists, check function bundle size and region configuration."
          }]
        else [] end )
    )
')"

echo "$issues_json" >"$ISSUES_FILE"

# ---------------------------------------------------------------------------
# Markdown report → stdout
# ---------------------------------------------------------------------------
{
  printf '### Synthetic HTTP probe — %s\n\n' "$VERCEL_PROJECT_ID"
  echo "- **Base URL:** ${BASE_URL} (source: ${base_source})"
  echo "- **Paths probed:** $(jq '.paths | length' "$OUT_JSON")"
  echo "- **OK / 4xx / 5xx / error:** $(jq -r '"\(.totals.ok) / \(.totals["4xx"]) / \(.totals["5xx"]) / \(.totals.error)"' "$OUT_JSON")"
  echo "- **Slow OK responses (>${slow_ms}ms):** $(jq -r '.totals.slow_ok' "$OUT_JSON")"
  echo "- **Per-request timeout:** ${timeout_s}s   **Success codes:** ${success_csv}"
  echo
  if [[ "$(jq '.paths | length' "$OUT_JSON")" -gt 0 ]]; then
    printf '| Method | Path | Code | Latency (ms) | Result | Effective URL |\n'
    printf '| --- | --- | ---: | ---: | --- | --- |\n'
    jq -r '
      .paths[]
      | "| \(.method) | `\(.path)` | \(.code) | \(.latency_ms) | \(.bucket) | \(.url_effective) |"
    ' "$OUT_JSON"
    echo
  fi
  printf 'Artifact: `%s`\n' "$OUT_JSON"
}
