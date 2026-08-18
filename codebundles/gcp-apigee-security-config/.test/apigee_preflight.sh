#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_preflight.sh -- assert the substrate contract BEFORE a bundle starts
# creating fixtures against it.
#
# SHARED SUBSTRATE. Byte-identical in every gcp-apigee-* bundle;
# check-shared-drift.sh fails `task ci` when it is not.
#
#   bash apigee_preflight.sh
#
# Source load-credentials.sh first.
#
# WHY THIS EXISTS, AND WHY IT ASSERTS NAMES RATHER THAN COUNTS.
#
# Four of the five bundles need environments they do not create. Before this,
# only gcp-apigee-proxy-health checked at all, and it checked the wrong thing:
#
#     env_count=$(... | jq length)
#     [ "$env_count" -eq 0 ] && fail "org has no environments."
#
# That asserts "at least one", while the bundle needs TWO -- its cross-
# environment revision-drift fixture deploys to a second environment. And the
# bootstrap script does not fail without one; it does this:
#
#     if [ -n "$env2" ]; then
#         deploy_revision "${SUFFIX}-proxy-drift" "$env2" "$rev2"
#     fi
#
# So with a single environment the drift fixture is SILENTLY SKIPPED, and
# check_revision_drift.sh then reports clean -- not because there is no drift,
# but because nothing was ever created to drift. A count-based check cannot
# catch that; only asserting the named contract can.
#
# gcp-apigee-environment-health, gcp-apigee-security-config and
# gcp-apigee-traffic-health had no substrate check at all, so their failure mode
# was a wall of 404s that reads as broken code rather than as missing
# prerequisites.
#
# Exits non-zero, naming what is missing and what to run, if the contract in
# apigee_prerequisites.sh is not satisfied.
# -----------------------------------------------------------------------------
set -uo pipefail

APIGEE_API="${APIGEE_API:-https://apigee.googleapis.com/v1}"

APIGEE_SUBSTRATE_SUFFIX="${APIGEE_SUBSTRATE_SUFFIX:-${TF_VAR_resource_suffix:-${RESOURCE_SUFFIX:-test001}}}"
APIGEE_ENV_HEALTHY="apigee-env-healthy-${APIGEE_SUBSTRATE_SUFFIX}"
APIGEE_ENV_UNATTACHED="apigee-env-unattached-${APIGEE_SUBSTRATE_SUFFIX}"

_org="${APIGEE_ORG:-${TF_VAR_org_id:-}}"
_org="${_org#organizations/}"
_project="${GCP_PROJECT_ID:-${TF_VAR_project_id:-}}"

fail() {
    echo "" >&2
    echo "PREFLIGHT FAILED: $1" >&2
    shift
    for line in "$@"; do echo "  $line" >&2; done
    echo "" >&2
    echo "  Run: task bootstrap-prerequisites" >&2
    echo "  It is idempotent and available in every gcp-apigee-* bundle, so it" >&2
    echo "  does not matter which one you run it from." >&2
    echo "" >&2
    exit 1
}

# xtrace is suppressed around the token and every request carrying it: this
# script may be sourced from a traced context, and the trace is what lands in
# captured output. State is saved and restored, never assumed.
_get() {
    local _xt=off _rc
    case "$-" in *x*) _xt=on ;; esac
    { set +x; } 2>/dev/null
    curl -fsS -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
        "${APIGEE_API}/$1" 2>/dev/null
    _rc=$?
    [ "${_xt}" = on ] && set -x
    return "${_rc}"
}

[ -n "${_project}" ] || fail "GCP_PROJECT_ID is not set." "Source load-credentials.sh first."

# --- a token can be minted ---------------------------------------------------
_have_token() {
    local _xt=off _t
    case "$-" in *x*) _xt=on ;; esac
    { set +x; } 2>/dev/null
    _t="$(gcloud auth print-access-token 2>/dev/null || true)"
    if [ -n "${_t}" ]; then _rc=0; else _rc=1; fi
    [ "${_xt}" = on ] && set -x
    return "${_rc}"
}
_have_token || fail "no gcloud access token." \
    "Activate the service account: gcloud auth activate-service-account --key-file=gcp.json.secret" \
    "or log in with: gcloud auth login"

# --- the organization exists and is ACTIVE -----------------------------------
[ -n "${_org}" ] || fail "APIGEE_ORG is not set and could not be resolved." \
    "tf.secret must set APIGEE_ORG or TF_VAR_org_id."

org_body="$(_get "organizations/${_org}")" \
    || fail "cannot read Apigee organization '${_org}'." \
        "Either it does not exist, or this credential cannot see it." \
        "Confirm the org name and that the service account has roles/apigee.admin."

org_state="$(printf '%s' "${org_body}" | jq -r '.state // ""')"
[ "${org_state}" = "ACTIVE" ] || fail "Apigee organization '${_org}' is '${org_state:-unknown}', not ACTIVE." \
    "An organization still provisioning cannot accept fixtures."

echo "Preflight: org '${_org}' is ACTIVE."

# --- both contract environments exist and are ACTIVE -------------------------
# Asserted BY NAME. See the header for why a count is not enough.
envs_body="$(_get "organizations/${_org}/environments")" \
    || fail "listing environments for org '${_org}' failed." \
        "Confirm the service account can read the organization."

# /environments is one of the UNDOCUMENTED endpoints that returns a BARE ARRAY
# OF STRINGS rather than an object with a named list field. Reading it as an
# object yields nothing and every assertion below would pass vacuously -- this
# family has rediscovered that trap three separate times.
env_list="$(printf '%s' "${envs_body}" \
    | jq -r 'if type=="array" then .[] elif type=="object" then ((.environments // [])[]) else empty end' 2>/dev/null)"

missing=""
for want in "${APIGEE_ENV_HEALTHY}" "${APIGEE_ENV_UNATTACHED}"; do
    printf '%s\n' "${env_list}" | grep -qx -- "${want}" || missing="${missing} ${want}"
done

if [ -n "${missing}" ]; then
    fail "the substrate environments are missing from org '${_org}':${missing}" \
        "Present: $(printf '%s' "${env_list}" | tr '\n' ' ')" \
        "" \
        "These are NOT any one bundle's fixtures. An EVALUATION organization" \
        "permits exactly two environments, so both are shared substrate and are" \
        "created by bootstrap-prerequisites in every bundle." \
        "" \
        "If the names above look wrong, every gcp-apigee-* bundle must agree on" \
        "APIGEE_SUBSTRATE_SUFFIX (currently '${APIGEE_SUBSTRATE_SUFFIX}')."
fi

echo "Preflight: environments '${APIGEE_ENV_HEALTHY}' and '${APIGEE_ENV_UNATTACHED}' present."

# --- exactly one runtime instance, with the healthy env attached -------------
inst_body="$(_get "organizations/${_org}/instances")" || inst_body='{}'
inst_names="$(printf '%s' "${inst_body}" | jq -r '(.instances // []) | .[].name' 2>/dev/null)"
inst_count="$(printf '%s' "${inst_names}" | grep -c . || true)"

[ "${inst_count}" -ge 1 ] || fail "org '${_org}' has no runtime instance." \
    "Proxies cannot be deployed and no traffic metric will ever be produced." \
    "An EVALUATION organization permits exactly one; bootstrap creates it."

first_inst="$(printf '%s' "${inst_names}" | head -n1)"
att_body="$(_get "organizations/${_org}/instances/${first_inst}/attachments")" || att_body='{}'
attached="$(printf '%s' "${att_body}" | jq -r '(.attachments // []) | .[].environment' 2>/dev/null)"

printf '%s\n' "${attached}" | grep -qx -- "${APIGEE_ENV_HEALTHY}" \
    || fail "environment '${APIGEE_ENV_HEALTHY}' is not attached to runtime instance '${first_inst}'." \
        "Attached: $(printf '%s' "${attached}" | tr '\n' ' ')" \
        "An unattached environment cannot serve traffic, so proxy deployments" \
        "there produce no metrics and every traffic check reads as 'no data'."

echo "Preflight: instance '${first_inst}' present, '${APIGEE_ENV_HEALTHY}' attached."

# apigee-env-unattached-* MUST NOT be attached. It is the known-positive for
# check_instance_attachments -- see THE SUBSTRATE CONTRACT in
# apigee_prerequisites.sh. Attaching it "to tidy up" makes that check pass
# because there is nothing to find, which is not the same as passing because
# the org is healthy. Warn rather than fail: the substrate is still usable, but
# one bundle's known-positive has quietly gone.
if printf '%s\n' "${attached}" | grep -qx -- "${APIGEE_ENV_UNATTACHED}"; then
    echo "" >&2
    echo "WARNING: '${APIGEE_ENV_UNATTACHED}' IS attached to '${first_inst}'." >&2
    echo "         Being unattached is a FIXTURE, not a defect -- it is" >&2
    echo "         gcp-apigee-environment-health's known-positive for" >&2
    echo "         check_instance_attachments, which will now pass because there" >&2
    echo "         is nothing to find rather than because the org is healthy." >&2
    echo "         Detach it: DELETE .../instances/${first_inst}/attachments/{id}" >&2
    echo "" >&2
fi

echo "Preflight: substrate contract satisfied."
