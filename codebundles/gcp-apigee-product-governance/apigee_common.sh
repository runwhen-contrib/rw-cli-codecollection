#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_common.sh -- shared helpers for the gcp-apigee-product-governance bundle
# (and, by intent, its siblings gcp-apigee-environment-health and
#  gcp-apigee-proxy-health).
#
# Centralizes four concerns so downstream scripts stay small and consistent:
#   1. OAuth token acquisition for the Apigee management REST API
#   2. Apigee organization resolution (explicit vs. discovered from the project)
#   3. Paged, typed list fetches for products / apps / developers
#   4. Access-failure tracking, so "could not run" is never reported as healthy
#
# Source this file from each task script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/apigee_common.sh"
#
# Required env:
#   GCP_PROJECT_ID   - the GCP project that owns the Apigee organization.
#   APIGEE_ORG       - optional; if empty it is resolved from GCP_PROJECT_ID.
#
# ---- The access-failure contract --------------------------------------------
# Every check script MUST write two files:
#   <prefix>_issues.json  - JSON array of findings (possibly empty)
#   <prefix>_status.json  - {"access_ok": bool, "reason": string}
#
# An empty issues array means "ran, found nothing" ONLY when access_ok is true.
# When a required API call fails, access_ok is false and the SLI scores that
# dimension 0 rather than 1. This is what keeps a blind run from reporting a
# perfect health score.
#
# Because fetch helpers run inside command substitutions (subshells), failures
# are recorded in a FILE rather than a shell variable -- a variable set in a
# subshell would be lost in the parent.
# -----------------------------------------------------------------------------

set -euo pipefail

APIGEE_BASE="${APIGEE_BASE:-https://apigee.googleapis.com/v1}"

# Apigee caps every list endpoint at 1000 records per call.
APIGEE_PAGE_SIZE="${APIGEE_PAGE_SIZE:-1000}"

# Upper bound on pages followed by any single listing. A server that keeps
# handing back a page token would otherwise spin until the task timeout and
# produce no output at all.
APIGEE_MAX_PAGES="${APIGEE_MAX_PAGES:-100}"

# Failure ledger. Reset each time this library is sourced, i.e. once per script
# run, so each check reports on its own fetches.
APIGEE_FAILURE_LOG="${APIGEE_FAILURE_LOG:-.apigee_access_failures}"
: > "$APIGEE_FAILURE_LOG"

# apigee_note_failure <reason>: record that a required API call could not be
# completed. Any entry makes the run's status access_ok=false.
apigee_note_failure() {
  printf '%s\n' "$1" >> "$APIGEE_FAILURE_LOG"
}

# apigee_access_ok: true when no required call has failed.
apigee_access_ok() {
  [ ! -s "$APIGEE_FAILURE_LOG" ]
}

# apigee_write_status <file>: emit the {"access_ok":..,"reason":..} sidecar.
apigee_write_status() {
  local file="$1" reason="" ok="true"
  if [ -s "$APIGEE_FAILURE_LOG" ]; then
    ok="false"
    reason="$(jq -Rs 'split("\n") | map(select(. != "")) | join("; ")' < "$APIGEE_FAILURE_LOG" | jq -r .)"
  fi
  jq -n --argjson ok "$ok" --arg reason "$reason" \
    '{access_ok: $ok, reason: $reason}' > "$file"
}

# apigee_urlencode <string>: percent-encode a query-parameter value.
apigee_urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

# apigee_issue <title> <details> <severity> <next_steps> <expected> <actual> [extra_json]
# Emits one compact JSON issue object. Built with jq so that names containing
# quotes, backslashes or newlines cannot corrupt the output -- Apigee display
# names routinely contain quotes.
apigee_issue() {
  local title="$1" details="$2" severity="$3" next_steps="$4"
  local expected="$5" actual="$6" extra="${7:-}"
  [ -z "$extra" ] && extra='{}'
  jq -cn \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --argjson extra "$extra" \
    '{title:$title, details:$details, severity:$severity, next_steps:$next_steps,
      expected:$expected, actual:$actual} + $extra'
}

# apigee_token: export an OAuth2 access token for the Apigee management API.
# Prefers APIGEE_TOKEN if already provided, otherwise derives one from the
# active gcloud service account (activated in the Suite Setup via
# `gcloud auth activate-service-account`).
apigee_token() {
  if [ -n "${APIGEE_TOKEN:-}" ]; then
    export APIGEE_TOKEN
    return 0
  fi
  if command -v gcloud >/dev/null 2>&1; then
    APIGEE_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
  fi
  if [ -z "${APIGEE_TOKEN:-}" ]; then
    echo "ERROR: Unable to obtain a GCP access token. Activate a service account" >&2
    echo "       (gcloud auth activate-service-account --key-file=<sa.json>) or" >&2
    echo "       set APIGEE_TOKEN." >&2
    return 1
  fi
  export APIGEE_TOKEN
}

# resolve_apigee_org: export APIGEE_ORG. Uses the explicit value if provided,
# otherwise discovers the Apigee organization bound to GCP_PROJECT_ID.
#
# Returns:
#   0 - resolved; APIGEE_ORG is exported
#   2 - the organization list was read successfully and NO organization is bound
#       to this project. The project simply does not use Apigee.
#   1 - the organization list could not be read, so which case applies is
#       unknown.
#
# The 2-vs-1 distinction matters. This bundle is generated for every GCP
# project, and most projects have no Apigee organization at all. Treating
# "no Apigee here" as a failure would paint every such project red, while
# treating "cannot read Apigee" as an empty org would paint a genuinely broken
# one green. They are different states and are scored differently.
#
# NOTE: organizations.list takes `parent` as a PATH parameter constrained to
# `organizations` -- there is no `?parent=projects/...` query filter. The call
# therefore returns every organization the caller can see, so the result must be
# filtered on the response's own projectId field. Picking the first entry
# blindly can audit an organization that belongs to a different project.
resolve_apigee_org() {
  : "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
  if [ -n "${APIGEE_ORG:-}" ]; then
    export APIGEE_ORG
    return 0
  fi
  apigee_token || return 1

  local orgs listed_ok=1
  if orgs="$(curl -fsS -H "Authorization: Bearer $APIGEE_TOKEN" \
      "$APIGEE_BASE/organizations" 2>/dev/null)"; then
    if printf '%s' "$orgs" | jq -e . >/dev/null 2>&1; then
      listed_ok=0
    fi
  fi

  if [ "$listed_ok" -eq 0 ]; then
    # OrganizationProjectMapping carries the bare organization name plus the
    # associated projectId (projectIds[] is the deprecated spelling).
    APIGEE_ORG="$(printf '%s' "$orgs" | jq -r --arg p "$GCP_PROJECT_ID" '
      [ (.organizations // [])[]
        | select((.projectId == $p) or ((.projectIds // []) | index($p))) ]
      | .[0].organization // empty' 2>/dev/null || true)"
    if [ -n "${APIGEE_ORG:-}" ]; then
      export APIGEE_ORG
      return 0
    fi
    # The list was readable and contained no organization for this project.
    return 2
  fi

  # The REST listing was unreadable; try gcloud before giving up.
  if command -v gcloud >/dev/null 2>&1; then
    APIGEE_ORG="$(gcloud apigee organizations list --project="$GCP_PROJECT_ID" \
      --format="value(name)" 2>/dev/null | head -n 1 || true)"
    if [ -n "${APIGEE_ORG:-}" ]; then
      export APIGEE_ORG
      return 0
    fi
  fi

  echo "ERROR: Could not determine whether project $GCP_PROJECT_ID has an" >&2
  echo "       Apigee organization; the organization list was unreadable." >&2
  echo "       Set APIGEE_ORG explicitly, or grant roles/apigee.readOnlyAdmin." >&2
  return 1
}

# apigee_finish_not_applicable <issues_file> <status_file>: emit the outputs for
# a project that has no Apigee organization. This is a successful, informative
# result -- the API was read and the answer was "nothing to govern" -- so
# access_ok stays true and the dimension scores healthy rather than red.
apigee_finish_not_applicable() {
  echo '[]' > "$1"
  apigee_write_status "$2"
  echo "No Apigee organization is bound to project $GCP_PROJECT_ID; nothing to check."
}

# apigee_api_get <relative-path>: authenticated GET. Prints the JSON body on
# success; prints nothing and returns non-zero on transport/HTTP error.
apigee_api_get() {
  local path="$1"
  apigee_token || return 1
  curl -fsS -H "Authorization: Bearer $APIGEE_TOKEN" "$APIGEE_BASE/$path"
}

# apigee_get_required <relative-path> <description>: fetch a document the caller
# genuinely needs. On failure the reason is recorded in the failure ledger and
# the function returns non-zero -- it never substitutes an empty document
# silently.
apigee_get_required() {
  local path="$1" what="$2" body
  if ! body="$(apigee_api_get "$path" 2>/dev/null)"; then
    apigee_note_failure "$what (GET $path failed)"
    return 1
  fi
  if [ -z "$body" ] || ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    apigee_note_failure "$what (GET $path returned an unparseable body)"
    return 1
  fi
  printf '%s' "$body"
}

# apigee_list_api_products: all API products, expanded, as a JSON array.
# apiproducts.list paginates with startKey/count and returns no page token; the
# startKey record is repeated as the first element of the next page.
apigee_list_api_products() {
  local out="[]" start_key="" prev_key="" page batch n query pages=0
  while :; do
    query="expand=true&count=$APIGEE_PAGE_SIZE"
    if [ -n "$start_key" ]; then
      query="$query&startKey=$(apigee_urlencode "$start_key")"
    fi
    page="$(apigee_get_required "organizations/$APIGEE_ORG/apiproducts?$query" \
      "Cannot list API products in org $APIGEE_ORG")" || return 1
    batch="$(printf '%s' "$page" | jq -c '.apiProduct // []')"
    n="$(printf '%s' "$batch" | jq 'length')"
    if [ -n "$start_key" ]; then
      batch="$(printf '%s' "$batch" | jq -c '.[1:]')"
    fi
    out="$(jq -cn --argjson a "$out" --argjson b "$batch" '$a + $b')"
    [ "$n" -lt "$APIGEE_PAGE_SIZE" ] && break

    prev_key="$start_key"
    start_key="$(printf '%s' "$batch" | jq -r '.[-1].name // empty')"
    [ -z "$start_key" ] && break
    # A cursor that does not advance would loop forever; treat it as a failed
    # listing rather than hanging until the task timeout.
    if [ "$start_key" = "$prev_key" ]; then
      apigee_note_failure "API product pagination did not advance past '$start_key' in org $APIGEE_ORG"
      return 1
    fi
    pages=$((pages + 1))
    if [ "$pages" -ge "$APIGEE_MAX_PAGES" ]; then
      apigee_note_failure "API product listing exceeded $APIGEE_MAX_PAGES pages in org $APIGEE_ORG"
      return 1
    fi
  done
  printf '%s' "$out"
}

# apigee_list_apps: all developer apps, expanded, with credentials, as an array.
#
# Two request parameters matter and are set explicitly rather than left to
# their defaults:
#   includeCred=true  - credentials are what every downstream check reads
#   status=approved   - the API default. Revoked apps are intentionally out of
#                       scope for governance; making it explicit means the
#                       filter is visible in the request rather than implied.
# Note that keyStatus also defaults to `approved`, so credentials that have been
# revoked are not enumerated. That is correct for expiry checking (a revoked key
# needs no rotation) but means dangling references held only by revoked keys are
# not reported. See README "Known limitations".
apigee_list_apps() {
  local out="[]" token="" prev_token="" page batch query pages=0
  while :; do
    query="expand=true&includeCred=true&status=approved&pageSize=$APIGEE_PAGE_SIZE"
    if [ -n "$token" ]; then
      query="$query&pageToken=$(apigee_urlencode "$token")"
    fi
    page="$(apigee_get_required "organizations/$APIGEE_ORG/apps?$query" \
      "Cannot list developer apps in org $APIGEE_ORG")" || return 1
    batch="$(printf '%s' "$page" | jq -c '.app // []')"
    out="$(jq -cn --argjson a "$out" --argjson b "$batch" '$a + $b')"

    prev_token="$token"
    token="$(printf '%s' "$page" | jq -r '.nextPageToken // empty')"
    [ -z "$token" ] && break
    # A page token that repeats would loop forever; treat it as a failed
    # listing rather than hanging until the task timeout.
    if [ "$token" = "$prev_token" ]; then
      apigee_note_failure "Developer app pagination did not advance past token '$token' in org $APIGEE_ORG"
      return 1
    fi
    pages=$((pages + 1))
    if [ "$pages" -ge "$APIGEE_MAX_PAGES" ]; then
      apigee_note_failure "Developer app listing exceeded $APIGEE_MAX_PAGES pages in org $APIGEE_ORG"
      return 1
    fi
  done
  printf '%s' "$out"
}

# apigee_list_developers: all developers, expanded, as a JSON array.
#
# developers.list rejects `expand` when combined with `count`/`startKey`, so the
# expanded form cannot be paginated and is capped at 1000 records. Without
# expand the response carries email addresses only -- no status, no developerId
# -- which silently disables every developer check, so expand is mandatory here.
# Callers should use apigee_developers_truncated to detect the cap.
apigee_list_developers() {
  local page
  page="$(apigee_get_required "organizations/$APIGEE_ORG/developers?expand=true" \
    "Cannot list developers in org $APIGEE_ORG")" || return 1
  printf '%s' "$page" | jq -c '.developer // []'
}

# apigee_developers_truncated <developers-json>: 0 when the 1000-record cap was
# hit and the list is therefore incomplete.
apigee_developers_truncated() {
  [ "$(printf '%s' "$1" | jq 'length')" -ge "$APIGEE_PAGE_SIZE" ]
}
