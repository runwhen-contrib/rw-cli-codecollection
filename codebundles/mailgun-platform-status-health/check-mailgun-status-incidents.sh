#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reads Mailgun Statuspage JSON (public) for overall status, degraded components,
# unresolved incidents, and active scheduled maintenance. Writes a JSON array of
# issues for the runbook to surface.
# Env: MAILGUN_STATUS_LOOKBACK_HOURS (optional, used for report context only)
# -----------------------------------------------------------------------------

OUTPUT_FILE="${OUTPUT_FILE:-status_incidents_output.json}"
MAILGUN_STATUS_LOOKBACK_HOURS="${MAILGUN_STATUS_LOOKBACK_HOURS:-24}"

STATUS_URL="https://status.mailgun.com/api/v2/status.json"
SUMMARY_URL="https://status.mailgun.com/api/v2/summary.json"
UNRESOLVED_URL="https://status.mailgun.com/api/v2/incidents/unresolved.json"
MAINT_URL="https://status.mailgun.com/api/v2/scheduled-maintenances/active.json"

issues_json='[]'

append_issue() {
  local title="$1"
  local expected="$2"
  local actual="$3"
  local details="$4"
  local severity="$5"
  local next_steps="$6"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, expected: $expected, actual: $actual, details: $details, severity: $severity, next_steps: $next_steps}]')
}

if ! status_raw=$(curl -fsS --connect-timeout 10 --max-time 60 "$STATUS_URL" 2>/dev/null); then
  append_issue \
    "Cannot fetch Mailgun status page JSON" \
    "HTTPS GET to the public Statuspage summary succeeds" \
    "curl to ${STATUS_URL} failed" \
    "GET ${STATUS_URL} failed (network, DNS, or HTTP error). Confirm outbound HTTPS access to status.mailgun.com." \
    4 \
    "Retry from a host with internet access; verify firewall and proxy rules for status.mailgun.com."
else
  indicator=$(echo "$status_raw" | jq -r '.status.indicator // "unknown"')
  description=$(echo "$status_raw" | jq -r '.status.description // ""')
  if [[ "$indicator" != "none" ]]; then
    sev=3
    if [[ "$indicator" == "minor" ]]; then sev=2; fi
    if [[ "$indicator" == "critical" ]]; then sev=4; fi
    append_issue \
      "Mailgun status indicator is not green (${indicator})" \
      "Statuspage indicator is none (all systems operational)" \
      "indicator=${indicator}; description=${description}" \
      "Statuspage indicator: ${indicator}. Summary: ${description}. Lookback context: ${MAILGUN_STATUS_LOOKBACK_HOURS}h." \
      "$sev" \
      "Review https://status.mailgun.com for live updates, subscribe to notifications, and pause risky mail changes until green."
  fi
fi

if ! summary_raw=$(curl -fsS --connect-timeout 10 --max-time 60 "$SUMMARY_URL" 2>/dev/null); then
  append_issue \
    "Cannot fetch Mailgun status summary JSON" \
    "HTTPS GET to the Statuspage summary.json succeeds" \
    "GET ${SUMMARY_URL} failed" \
    "Unable to evaluate per-component health from Statuspage summary." \
    4 \
    "Check connectivity to status.mailgun.com and retry; confirm corporate proxies allow Statuspage APIs."
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name=$(echo "$line" | cut -d$'\t' -f1)
    cstat=$(echo "$line" | cut -d$'\t' -f2)
    if [[ "$cstat" != "operational" ]]; then
      append_issue \
        "Mailgun component not operational: ${name}" \
        "All Statuspage components report operational status" \
        "component=${name} status=${cstat}" \
        "Component '${name}' reports status '${cstat}' in the Statuspage summary API." \
        3 \
        "Monitor https://status.mailgun.com, defer non-urgent sends if the component maps to your integration, and retest reachability tasks after recovery."
    fi
  done < <(echo "$summary_raw" | jq -r '.. | objects | select(has("name") and has("status") and (.name|type=="string")) | [.name,.status] | @tsv' 2>/dev/null || true)
fi

if ! unres_raw=$(curl -fsS --connect-timeout 10 --max-time 60 "$UNRESOLVED_URL" 2>/dev/null); then
  append_issue \
    "Cannot fetch Mailgun unresolved incidents" \
    "HTTPS GET to incidents/unresolved.json succeeds" \
    "GET ${UNRESOLVED_URL} failed" \
    "Unable to list unresolved incidents from the Statuspage API." \
    3 \
    "Verify access to the Mailgun status API; use the web status page as a fallback."
else
  count=$(echo "$unres_raw" | jq '.incidents | length')
  if [[ "${count:-0}" -gt 0 ]]; then
    idx=0
    while [[ "$idx" -lt "$count" ]]; do
      inc=$(echo "$unres_raw" | jq -c ".incidents[$idx]")
      name=$(echo "$inc" | jq -r '.name // "Incident"')
      impact=$(echo "$inc" | jq -r '.impact // "unknown"')
      istatus=$(echo "$inc" | jq -r '.status // "unknown"')
      shortlink=$(echo "$inc" | jq -r '.shortlink // empty')
      append_issue \
        "Active Mailgun incident: ${name}" \
        "No unresolved incidents on the public status page" \
        "impact=${impact}; status=${istatus}; link=${shortlink}" \
        "Unresolved incident from Statuspage: impact=${impact}, status=${istatus}. Link: ${shortlink}" \
        3 \
        "Follow the incident timeline on the status page, adjust traffic or retries as advised, and confirm regional API tasks once resolved."
      idx=$((idx + 1))
    done
  fi
fi

if ! maint_raw=$(curl -fsS --connect-timeout 10 --max-time 60 "$MAINT_URL" 2>/dev/null); then
  append_issue \
    "Cannot fetch Mailgun active scheduled maintenances" \
    "HTTPS GET to scheduled-maintenances/active.json succeeds" \
    "GET ${MAINT_URL} failed" \
    "Unable to list active maintenance windows." \
    2 \
    "Confirm HTTPS access; check the web status page for maintenance banners."
else
  mcount=$(echo "$maint_raw" | jq '.scheduled_maintenances | length')
  if [[ "${mcount:-0}" -gt 0 ]]; then
    midx=0
    while [[ "$midx" -lt "$mcount" ]]; do
      m=$(echo "$maint_raw" | jq -c ".scheduled_maintenances[$midx]")
      mname=$(echo "$m" | jq -r '.name // "Maintenance"')
      mstat=$(echo "$m" | jq -r '.status // "unknown"')
      append_issue \
        "Mailgun scheduled maintenance in progress: ${mname}" \
        "No active maintenance window affecting the platform" \
        "maintenance=${mname} status=${mstat}" \
        "Active maintenance window reported by Statuspage (status=${mstat})." \
        2 \
        "Plan around the window, expect possible API or control-plane noise, and re-run checks after maintenance completes."
      midx=$((midx + 1))
    done
  fi
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))"
