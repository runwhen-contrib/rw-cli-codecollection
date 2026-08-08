#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_common.sh -- shared helpers for the gcp-apigee-product-governance bundle
# (and, by intent, its siblings gcp-apigee-environment-health and
#  gcp-apigee-proxy-health).
#
# Centralizes three concerns so downstream scripts stay small and consistent:
#   1. OAuth token acquisition for the Apigee management REST API
#   2. Apigee organization resolution (explicit vs. discovered from the project)
#   3. REST paging + defensive error handling
#
# Source this file from each task script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/apigee_common.sh"
#
# Required env:
#   GCP_PROJECT_ID   - the GCP project that owns the Apigee organization.
#   APIGEE_ORG       - optional; if empty it is resolved from GCP_PROJECT_ID.
# -----------------------------------------------------------------------------

set -euo pipefail

APIGEE_BASE="${APIGEE_BASE:-https://apigee.googleapis.com/v1}"

# apigee_token: export an OAuth2 access token for the Apigee management API.
# Prefers APIGEE_TOKEN if already provided, otherwise derives one from the
# active gcloud service account (activated in the runbook Suite Setup via
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
resolve_apigee_org() {
  : "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
  if [ -n "${APIGEE_ORG:-}" ]; then
    export APIGEE_ORG
    return 0
  fi
  apigee_token
  local orgs names
  orgs="$(curl -fsS -H "Authorization: Bearer $APIGEE_TOKEN" \
    "$APIGEE_BASE/organizations?parent=projects/$GCP_PROJECT_ID/locations/global" \
    2>/dev/null || echo '{}')"
  # ListOrganizationsResponse entries carry a full resource name like
  # "organizations/my-org"; normalize by stripping the prefix.
  names="$(echo "$orgs" | jq -r '[.organizations[]?.organization] | map(sub("^organizations/";"")) | .[]' 2>/dev/null || true)"
  APIGEE_ORG="$(echo "$names" | head -n 1)"
  if [ -z "$APIGEE_ORG" ]; then
    # Fallback: ask gcloud for the org(s) attached to the project.
    if command -v gcloud >/dev/null 2>&1; then
      APIGEE_ORG="$(gcloud apigee organizations list --project="$GCP_PROJECT_ID" \
        --format="value(name)" 2>/dev/null | head -n 1 | sed 's#^organizations/##' || true)"
    fi
  fi
  if [ -z "${APIGEE_ORG:-}" ]; then
    echo "ERROR: Could not resolve an Apigee organization for project $GCP_PROJECT_ID." >&2
    echo "       Set APIGEE_ORG explicitly." >&2
    return 1
  fi
  export APIGEE_ORG
}

# apigee_api_get: perform an authenticated GET against the management API.
# Usage: apigee_api_get "<relative-path>"
# Prints the JSON body on success. Prints nothing and returns non-zero on
# transport error; callers should `|| echo '{}'` if they want to degrade.
apigee_api_get() {
  local path="$1"
  apigee_token
  curl -fsS -H "Authorization: Bearer $APIGEE_TOKEN" "$APIGEE_BASE/$path"
}

# apigee_checked_get: like apigee_api_get but returns 0 with a body of "{}"
# on failure so scripts can fail soft. Prints the JSON body (or "{}").
apigee_checked_get() {
  apigee_api_get "$1" 2>/dev/null || echo '{}'
}

# apigee_jq_object(): normalize a list response that some endpoints return
# under different keys into a JSON array. Prints [] when nothing found.
#   list_key         the singular-ish key, e.g. "apiProduct" or "app"
#   extra_keys       comma-separated alternative keys (optional)
jq_bag_to_array() {
  local primary="$1"
  local alts="${2:-}"
  local filters=".[\"$primary\"]"
  if [ -n "$alts" ]; then
    IFS=',' read -r -a alt_arr <<< "$alts"
    for a in "${alt_arr[@]}"; do
      filters="$filters // .[\"$a\"]"
    done
  fi
  jq -c "$filters // []"
}
