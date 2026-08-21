#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_prerequisites.sh -- provision the substrate every gcp-apigee-* bundle
# needs before it can create any fixture: the enabled APIs, the peered VPC, the
# reserved Service Networking range, the peering connection, the Apigee
# organization, its two environments and its runtime instance.
#
# THE SUBSTRATE CONTRACT is stated in full below, including the one invariant
# that will otherwise get "tidied up". Read it before changing anything here.
#
# SHARED SUBSTRATE. This file is byte-identical in every gcp-apigee-* bundle and
# check-shared-drift.sh fails `task ci` when it is not. Edit it in one bundle,
# then copy it to the others in the same commit.
#
#   bash apigee_prerequisites.sh bootstrap
#   bash apigee_prerequisites.sh destroy
#
# Source load-credentials.sh first: it resolves GCP_PROJECT_ID and APIGEE_ORG
# from the several spellings tf.secret is written in, and exits non-zero when
# the credentials are absent rather than letting a run proceed against nothing.
#
# WHY THIS IS NOT TERRAFORM.
#
# All of it used to live in gcp-apigee-environment-health's main.tf, which made
# every other bundle a silent guest: run gcp-apigee-proxy-health on a fresh
# project and its fixtures 404, because nothing in that bundle creates the org
# and environments they hang off. The reason the block could not simply be
# copied into the other four is state ownership, not idempotency -- five
# Terraform states cannot each `create` the same VPC, address and peering. The
# second one to run errors "already exists", because Terraform converges within
# a state and does not adopt a resource another state owns.
#
# Expressed as check-then-create over gcloud/REST there is no state to own, so
# the same block is safely duplicable into all five. Whichever bundle runs
# first creates the substrate; the rest observe it and continue. That also
# removes the bug class where one bundle's `terraform destroy` takes out
# substrate the other four are sitting on (#745, and again in #733).
#
# CONCURRENCY. Two bundles may bootstrap at the same time, so every create here
# treats "it already exists" as success -- HTTP 409 on the organization,
# ALREADY_EXISTS from gcloud -- and falls through to the same readiness poll
# the winner runs. Anything that races is therefore a no-op, not a failure.
#
# ORDERING ON TEARDOWN is the reverse and is NOT symmetric with bootstrap:
# peering connection -> reserved range -> network -> disable APIs, and the API
# list disabled is apigee + apigeeconnect ONLY. servicenetworking is shared
# with every other private-services user in the project; disabling it is how
# you break Cloud SQL and Memorystore in a project that was only meant to lose
# its Apigee org.
# -----------------------------------------------------------------------------
set -uo pipefail

APIGEE_API="${APIGEE_API:-https://apigee.googleapis.com/v1}"

# Enabled on bootstrap. servicenetworking is included here because the peering
# connection cannot be made without it -- but see the teardown note above: it is
# deliberately NOT in the disable list.
APIGEE_REQUIRED_APIS="apigee.googleapis.com apigeeconnect.googleapis.com servicenetworking.googleapis.com"
# Disabled on teardown. Narrower than the enable list, on purpose.
APIGEE_TEARDOWN_APIS="apigee.googleapis.com apigeeconnect.googleapis.com"

# The reserved range is NOT suffixed per run. It is bound to the organization's
# authorizedNetwork, which can only be changed while no runtime instance exists,
# so it shares the org's lifetime rather than an individual test run's -- and a
# per-bundle suffix would give five bundles five different ranges for one org,
# which is exactly what stops the block being duplicable.
#
# main.tf used to name it apigee-peering-${suffix}. adopt_existing_range() below
# finds such a range and reuses it, so a project bootstrapped before this change
# does not get a second one.
APIGEE_PEERING_RANGE="${APIGEE_PEERING_RANGE:-apigee-peering}"

# --- THE SUBSTRATE CONTRACT --------------------------------------------------
#
# What bootstrap guarantees, and what apigee_preflight.sh asserts before any
# bundle creates a fixture:
#
#     org  <project>                      ACTIVE
#     env  apigee-env-healthy-<sfx>       ACTIVE, attached to the runtime instance
#     env  apigee-env-unattached-<sfx>    ACTIVE, deliberately NOT attached
#          exactly one runtime instance   (EVALUATION cap)
#
# *** apigee-env-unattached-* BEING UNATTACHED IS A FIXTURE, NOT A DEFECT. ***
#
# It is gcp-apigee-environment-health's known-positive for
# check_instance_attachments: an environment with no instance attachment is the
# exact condition that check exists to detect. Attaching it "to tidy up" deletes
# the known-positive and makes the check pass for the wrong reason -- it would
# then report clean because there is nothing to find, which is indistinguishable
# from reporting clean because it looked and the org is healthy. Leave it alone.
#
# It is also gcp-apigee-proxy-health's second environment: a proxy deploys to an
# environment with no instance attached and still appears under
# /organizations/{org}/deployments carrying `environment` and `revision`, which
# is what the cross-environment revision-drift fixture needs. (Probed
# 2026-08-10, HTTP 200. Caveat from the same probe: `state` came back null for
# both environments in the org-wide deployments view, so a check keying on
# deployment STATE rather than revision is unverified on this topology.)
#
# WHY ENVIRONMENTS ARE SUBSTRATE AND NOT ONE BUNDLE'S FIXTURES.
#
# An EVALUATION organization is hard-capped:
#
#     the number of environments cannot exceed 2 for TRIAL subscription
#     the number of instance cannot exceed the limit 1
#
# Two environment slots and one instance slot, shared by five bundles. A capped
# resource is inherently shared, which is what makes it substrate by definition
# -- and putting these in gcp-apigee-environment-health's Terraform was the same
# category error C8 fixed one level down, with the same symptom: four bundles
# silently depending on a fifth having been run first, invisible until the
# fixtures 404.
#
# ONE SUFFIX ACROSS ALL FIVE BUNDLES.
#
# Because the slots are capped, the substrate names cannot vary per bundle: two
# bundles with different suffixes would want four environments and the third
# create would fail on quota. APIGEE_SUBSTRATE_SUFFIX therefore has to be the
# same everywhere, and _check_environment_slots below fails by name rather than
# letting the quota error do it. It defaults to the per-run fixture suffix,
# which is correct as long as that is also shared -- set it explicitly when it
# is not.
APIGEE_SUBSTRATE_SUFFIX="${APIGEE_SUBSTRATE_SUFFIX:-${TF_VAR_resource_suffix:-${RESOURCE_SUFFIX:-test001}}}"
APIGEE_ENV_HEALTHY="apigee-env-healthy-${APIGEE_SUBSTRATE_SUFFIX}"
APIGEE_ENV_UNATTACHED="apigee-env-unattached-${APIGEE_SUBSTRATE_SUFFIX}"
APIGEE_INSTANCE="apigee-inst-primary-${APIGEE_SUBSTRATE_SUFFIX}"

_project="${GCP_PROJECT_ID:-${TF_VAR_project_id:-}}"
_org="${APIGEE_ORG:-${TF_VAR_org_id:-}}"
_org="${_org#organizations/}"
_network="${TF_VAR_network:-default}"
_region="${TF_VAR_region:-us-west1}"
_suffix="${TF_VAR_resource_suffix:-${RESOURCE_SUFFIX:-test001}}"
_create_network="${TF_VAR_create_network:-false}"
_prefix_length="${TF_VAR_peering_prefix_length:-21}"
_peering_disabled="${TF_VAR_disable_vpc_peering:-false}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo "==> $*"; }
note() { echo "    $*"; }

[ -n "${_project}" ] || die "GCP_PROJECT_ID (or TF_VAR_project_id) must be set. Source load-credentials.sh first."
[ -n "${_org}" ] || die "APIGEE_ORG (or TF_VAR_org_id) must be set. Source load-credentials.sh first."

# A token is minted per call rather than once at the top: bootstrap polls for up
# to fifteen minutes, which outlives a one-hour token only rarely but outlives a
# short-lived impersonated one routinely.
#
# xtrace is suppressed around the mint and around every request that carries the
# result. `set -x` expands the bearer token into the trace, and the trace is what
# lands in captured task output. `{ set +x; } 2>/dev/null` disables tracing
# without the disable itself being traced; the saved state is restored after, so
# sourcing this from an untraced shell does not switch tracing on.
_token() {
    local _was_traced=0 _t
    case "$-" in *x*) _was_traced=1 ;; esac
    { set +x; } 2>/dev/null
    _t="$(gcloud auth print-access-token 2>/dev/null)" \
        || _t="$(gcloud auth application-default print-access-token 2>/dev/null)" \
        || _t=""
    printf '%s' "${_t}"
    [ "${_was_traced}" = 1 ] && set -x
    return 0
}

# api_get <url> -> body on stdout, exit status of curl
_api_get() {
    local _was_traced=0 _rc
    case "$-" in *x*) _was_traced=1 ;; esac
    { set +x; } 2>/dev/null
    curl -fsS -H "Authorization: Bearer $(_token)" "$1" 2>/dev/null
    _rc=$?
    [ "${_was_traced}" = 1 ] && set -x
    return "${_rc}"
}

# api_post <url> <json_body> <outfile> -> HTTP status on stdout
_api_post() {
    local _was_traced=0 _code
    case "$-" in *x*) _was_traced=1 ;; esac
    { set +x; } 2>/dev/null
    _code="$(curl -s -o "$3" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $(_token)" \
        -H "Content-Type: application/json" \
        "$1" -d "$2")"
    [ "${_was_traced}" = 1 ] && set -x
    printf '%s' "${_code}"
}

_org_exists() { _api_get "${APIGEE_API}/organizations/${_org}" >/dev/null 2>&1; }

# _await <url> <what> <max_polls> <interval>
#   Polls a resource until its .state is ACTIVE. Apigee environment and instance
#   creates are long-running operations: the POST returns 200 immediately and
#   the resource is unusable for minutes afterwards. Anything that creates one
#   and moves on will 404 on the very next call.
_await() {
    local url="$1" what="$2" max="$3" interval="$4" state="" i=0
    while [ "${i}" -lt "${max}" ]; do
        state="$(_api_get "${url}" 2>/dev/null | jq -r '.state // ""')"
        [ "${state}" = "ACTIVE" ] && { note "${what} is ACTIVE"; return 0; }
        note "${what}: state=${state:-pending} ..."
        sleep "${interval}"
        i=$((i + 1))
    done
    die "${what} did not reach ACTIVE in time (last state: ${state:-unknown})"
}

# _ensure_environment <name>
#   Idempotent create. 409 is a sibling bundle that got there first, and both
#   callers then wait on the same ACTIVE poll.
_ensure_environment() {
    local name="$1" url="${APIGEE_API}/organizations/${_org}/environments" out code
    if _api_get "${url}/${name}" >/dev/null 2>&1; then
        note "environment '${name}' already exists"
    else
        out="$(mktemp)"
        code="$(_api_post "${url}" "{\"name\":\"${name}\"}" "${out}")"
        case "${code}" in
            200|201) note "environment '${name}': creation accepted" ;;
            409)     note "environment '${name}': another bootstrap created it; waiting on it" ;;
            *)       echo "ERROR: could not create environment '${name}' (HTTP ${code})" >&2
                     cat "${out}" >&2; rm -f "${out}"; exit 1 ;;
        esac
        rm -f "${out}"
    fi
    _await "${url}/${name}" "environment '${name}'" 40 15
}

# _ensure_instance <name>
#   The slow one: 25-45 minutes on first create. Idempotent, so the bundles that
#   did not pay for it simply observe it.
_ensure_instance() {
    local name="$1" url="${APIGEE_API}/organizations/${_org}/instances" out code
    if _api_get "${url}/${name}" >/dev/null 2>&1; then
        note "runtime instance '${name}' already exists"
    else
        out="$(mktemp)"
        code="$(_api_post "${url}" \
            "{\"name\":\"${name}\",\"location\":\"${_region}\"}" "${out}")"
        case "${code}" in
            200|201) note "runtime instance '${name}': creation accepted (this takes 25-45 minutes)" ;;
            409)     note "runtime instance '${name}': another bootstrap created it; waiting on it" ;;
            *)       echo "ERROR: could not create runtime instance '${name}' (HTTP ${code})" >&2
                     cat "${out}" >&2
                     echo "NOTE: an EVALUATION organization permits exactly ONE runtime instance." >&2
                     rm -f "${out}"; exit 1 ;;
        esac
        rm -f "${out}"
    fi
    _await "${url}/${name}" "runtime instance '${name}'" 120 30
}

# _attachment_present <instance> <environment>
#   True once the attachment is visible in the list. The list only shows
#   COMPLETED attachments -- one that is mid-provision is absent from it -- so
#   this doubles as the readiness test.
_attachment_present() {
    _api_get "${APIGEE_API}/organizations/${_org}/instances/$1/attachments" 2>/dev/null \
        | jq -e --arg e "$2" \
            '(.attachments // []) | map(select(.environment == $e)) | length > 0' >/dev/null 2>&1
}

# _ensure_attachment <instance> <environment>
#   Attaching is what makes an environment able to serve traffic.
#
#   THIS IS A LONG-RUNNING OPERATION, like the environment and instance creates
#   above, and it was the one place that fact was not honoured. The POST returns
#   200 immediately with an Operation, provisioning then runs for minutes, and
#   the attachments list stays EMPTY throughout. The first version reported
#   "attached" off that 200 and returned -- so bootstrap declared the substrate
#   ready while the attachment was 25% done, and preflight, reading the same
#   empty list, correctly called it unattached. Bootstrap and preflight
#   disagreed on live infrastructure, which is exactly the class of silent
#   success this family exists to prevent.
#
#   The list is also why a naive retry is unsafe: absent-because-provisioning is
#   indistinguishable from absent-because-missing, so a second POST during the
#   window is not a no-op. Apigee rejects it with 400 FAILED_PRECONDITION and a
#   message naming the operation already in flight -- treated here as "someone
#   is already doing it", which is the correct outcome for a concurrent
#   bootstrap too.
_ensure_attachment() {
    local inst="$1" env="$2"
    local url="${APIGEE_API}/organizations/${_org}/instances/${inst}/attachments" out code
    if _attachment_present "${inst}" "${env}"; then
        note "environment '${env}' is already attached to '${inst}'"
        return 0
    fi
    out="$(mktemp)"
    code="$(_api_post "${url}" "{\"environment\":\"${env}\"}" "${out}")"
    case "${code}" in
        200|201) note "attachment of '${env}' accepted; provisioning" ;;
        409)     note "'${env}' was attached concurrently" ;;
        400)
            # Only the in-flight lock is benign. Any other 400 is a real error.
            if grep -q "is currently being attached\|locked by another operation" "${out}"; then
                note "'${env}' is already being attached by another operation; waiting on it"
            else
                echo "ERROR: could not attach '${env}' to '${inst}' (HTTP 400)" >&2
                cat "${out}" >&2; rm -f "${out}"; exit 1
            fi
            ;;
        *)       echo "ERROR: could not attach '${env}' to '${inst}' (HTTP ${code})" >&2
                 cat "${out}" >&2; rm -f "${out}"; exit 1 ;;
    esac
    rm -f "${out}"

    # Wait for it to actually exist. Without this the caller is told the
    # environment can serve traffic before it can.
    local i=0
    while [ "${i}" -lt 60 ]; do
        if _attachment_present "${inst}" "${env}"; then
            note "environment '${env}' is attached to '${inst}'"
            return 0
        fi
        note "attachment of '${env}': provisioning ..."
        sleep 20
        i=$((i + 1))
    done
    die "attachment of '${env}' to '${inst}' did not complete in time"
}

# _check_environment_slots
#   An EVALUATION org permits exactly TWO environments, and this contract claims
#   both. If they are already taken by environments this script did not create,
#   say so by name -- the alternative is a create that fails with a quota
#   message naming no culprit, which sends the next person to the wrong place.
_check_environment_slots() {
    local existing extra
    existing="$(_api_get "${APIGEE_API}/organizations/${_org}/environments" 2>/dev/null \
        | jq -r 'if type=="array" then .[] else empty end' 2>/dev/null)"
    [ -z "${existing}" ] && return 0
    extra="$(printf '%s\n' "${existing}" \
        | grep -vx -e "${APIGEE_ENV_HEALTHY}" -e "${APIGEE_ENV_UNATTACHED}" || true)"
    [ -z "${extra}" ] && return 0
    echo "ERROR: this organization's environment slots are held by environments" >&2
    echo "       this substrate did not create:" >&2
    printf '%s\n' "${extra}" | sed 's/^/         /' >&2
    echo "       An EVALUATION organization permits exactly TWO environments, and" >&2
    echo "       the substrate contract claims both:" >&2
    echo "         ${APIGEE_ENV_HEALTHY}" >&2
    echo "         ${APIGEE_ENV_UNATTACHED}" >&2
    echo "       Either delete the environments above, or point every gcp-apigee-*" >&2
    echo "       bundle at the same APIGEE_SUBSTRATE_SUFFIX so they agree on the names." >&2
    exit 1
}

# The range main.tf used to create. Reused rather than duplicated so a project
# bootstrapped before the Terraform-to-REST move keeps one peering range.
adopt_existing_range() {
    if gcloud compute addresses describe "${APIGEE_PEERING_RANGE}" \
         --global --project "${_project}" >/dev/null 2>&1; then
        return 0
    fi
    local legacy="apigee-peering-${_suffix}"
    if gcloud compute addresses describe "${legacy}" \
         --global --project "${_project}" >/dev/null 2>&1; then
        note "adopting the pre-existing reserved range '${legacy}'"
        APIGEE_PEERING_RANGE="${legacy}"
    fi
}

# --- bootstrap ---------------------------------------------------------------
bootstrap() {
    step "1/8 enabling required APIs"
    # `services enable` is natively idempotent and accepts several at once, so
    # there is nothing to check first. It is also the slowest step on a cold
    # project, which is why it is not run per-API in a loop.
    # SC2086: the unquoted expansion is the point -- the list must word-split
    # into separate arguments.
    # shellcheck disable=SC2086
    if ! gcloud services enable ${APIGEE_REQUIRED_APIS} --project "${_project}"; then
        die "could not enable the required APIs on project '${_project}'"
    fi
    note "enabled: ${APIGEE_REQUIRED_APIS}"

    step "2/8 VPC network '${_network}'"
    if gcloud compute networks describe "${_network}" --project "${_project}" >/dev/null 2>&1; then
        note "network '${_network}' already exists"
    elif [ "${_create_network}" = "true" ]; then
        # The create's own exit status is deliberately ignored and the result
        # verified instead: a sibling bundle bootstrapping concurrently makes
        # this fail with ALREADY_EXISTS, which is the outcome we wanted.
        gcloud compute networks create "${_network}" \
            --project "${_project}" --subnet-mode auto >/dev/null 2>&1
        gcloud compute networks describe "${_network}" --project "${_project}" >/dev/null 2>&1 \
            || die "could not create VPC network '${_network}'"
        note "network '${_network}' created"
    else
        die "VPC network '${_network}' does not exist and TF_VAR_create_network is not true."
    fi

    if [ "${_peering_disabled}" = "true" ]; then
        step "3/8 skipping the reserved range and peering (disable_vpc_peering=true)"
    else
        adopt_existing_range
        step "3/8 reserved Service Networking range '${APIGEE_PEERING_RANGE}'"
        if gcloud compute addresses describe "${APIGEE_PEERING_RANGE}" \
             --global --project "${_project}" >/dev/null 2>&1; then
            note "range '${APIGEE_PEERING_RANGE}' already reserved"
        else
            gcloud compute addresses create "${APIGEE_PEERING_RANGE}" \
                --global --project "${_project}" \
                --purpose VPC_PEERING --addresses "" \
                --prefix-length "${_prefix_length}" \
                --network "${_network}" >/dev/null 2>&1
            # Verify rather than trust the exit status: a concurrent creator
            # makes this fail with ALREADY_EXISTS, which is the outcome we want.
            gcloud compute addresses describe "${APIGEE_PEERING_RANGE}" \
                --global --project "${_project}" >/dev/null 2>&1 \
                || die "could not reserve the peering range '${APIGEE_PEERING_RANGE}'"
            note "range '${APIGEE_PEERING_RANGE}' reserved (/${_prefix_length})"
        fi

        step "4/8 service networking peering connection"
        if gcloud services vpc-peerings list \
             --network "${_network}" --project "${_project}" 2>/dev/null \
             | grep -q "${APIGEE_PEERING_RANGE}"; then
            note "peering connection already present"
        else
            gcloud services vpc-peerings connect \
                --service servicenetworking.googleapis.com \
                --ranges "${APIGEE_PEERING_RANGE}" \
                --network "${_network}" --project "${_project}" >/dev/null 2>&1
            gcloud services vpc-peerings list \
                --network "${_network}" --project "${_project}" 2>/dev/null \
                | grep -q "${APIGEE_PEERING_RANGE}" \
                || die "could not establish the service networking peering connection"
            note "peering connection established"
        fi
    fi

    step "5/8 Apigee organization '${_org}' (EVALUATION)"
    if _org_exists; then
        note "org '${_org}' already exists"
    else
        local body out code
        out="$(mktemp)"
        if [ "${_peering_disabled}" = "true" ]; then
            body="{\"name\":\"${_org}\",\"analyticsRegion\":\"${_region}\",\"runtimeType\":\"CLOUD\",\"billingType\":\"EVALUATION\",\"disableVpcPeering\":true}"
        else
            body="{\"name\":\"${_org}\",\"analyticsRegion\":\"${_region}\",\"runtimeType\":\"CLOUD\",\"billingType\":\"EVALUATION\",\"authorizedNetwork\":\"${_network}\"}"
        fi
        code="$(_api_post "${APIGEE_API}/organizations?parent=projects/${_project}" "${body}" "${out}")"
        case "${code}" in
            # 409 is a sibling bundle that got there first. Both callers then
            # wait on the same ACTIVE poll below, which is the correct outcome
            # for both -- treating it as an error made concurrent bootstrap a
            # coin flip.
            200|201) note "creation accepted" ;;
            409)     note "another bootstrap is already creating this org; waiting on it" ;;
            *)       echo "ERROR: org creation failed (HTTP ${code})" >&2; cat "${out}" >&2; rm -f "${out}"; exit 1 ;;
        esac
        rm -f "${out}"
    fi

    step "waiting for org '${_org}' to reach ACTIVE (~4 min for an EVALUATION org)"
    local state="" i=0
    while [ "${i}" -lt 60 ]; do
        state="$(_api_get "${APIGEE_API}/organizations/${_org}" 2>/dev/null | jq -r '.state // ""')"
        [ "${state}" = "ACTIVE" ] && break
        note "state=${state:-pending} ..."
        sleep 15
        i=$((i + 1))
    done
    [ "${state}" = "ACTIVE" ] || die "org '${_org}' did not reach ACTIVE in time (last state: ${state:-unknown})"

    # --- C9: the environments and the runtime instance are substrate too -----
    # Four of the five bundles need these and none of them can create their own:
    # the EVALUATION caps make the slots shared, and a shared resource cannot
    # belong to one bundle's fixtures. See THE SUBSTRATE CONTRACT above.
    step "6/8 environment slots"
    _check_environment_slots
    _ensure_environment "${APIGEE_ENV_HEALTHY}"
    # Deliberately NOT attached below -- read the contract before "fixing" it.
    _ensure_environment "${APIGEE_ENV_UNATTACHED}"

    step "7/8 runtime instance '${APIGEE_INSTANCE}'"
    note "first create takes 25-45 minutes; later bundles observe it in seconds"
    _ensure_instance "${APIGEE_INSTANCE}"

    step "8/8 attaching '${APIGEE_ENV_HEALTHY}' to '${APIGEE_INSTANCE}'"
    _ensure_attachment "${APIGEE_INSTANCE}" "${APIGEE_ENV_HEALTHY}"

    echo
    echo "Substrate ready:"
    echo "  org       ${_org}"
    echo "  env       ${APIGEE_ENV_HEALTHY}      (attached)"
    echo "  env       ${APIGEE_ENV_UNATTACHED}   (deliberately unattached -- a fixture)"
    echo "  instance  ${APIGEE_INSTANCE}"
    echo "Next: task build-infra"
}

# --- destroy -----------------------------------------------------------------
destroy() {
    # The one guard this needs, and the reason the whole block is safe to
    # duplicate into five bundles. Deleting the organization deletes everything
    # inside it, so "the org is gone" already means "no bundle's fixtures
    # remain" -- there is nothing further to scan for. Whichever bundle runs
    # this last succeeds; every earlier one refuses with the instruction below,
    # so the order bundles are torn down in stops mattering.
    if _org_exists; then
        echo "ERROR: Apigee org '${_org}' still exists." >&2
        echo "Delete it before removing the peering range and network it runs on:" >&2
        echo "  curl -X DELETE -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\" >&2
        echo "    ${APIGEE_API}/organizations/${_org}" >&2
        exit 1
    fi
    note "org '${_org}' is absent; the substrate is safe to remove"

    if [ "${_peering_disabled}" != "true" ]; then
        adopt_existing_range
        step "1/4 peering connection"
        if gcloud services vpc-peerings delete \
             --service servicenetworking.googleapis.com \
             --network "${_network}" --project "${_project}" --quiet >/dev/null 2>&1; then
            note "peering connection deleted"
        else
            note "no peering connection to delete"
        fi

        step "2/4 reserved range '${APIGEE_PEERING_RANGE}'"
        if gcloud compute addresses delete "${APIGEE_PEERING_RANGE}" \
             --global --project "${_project}" --quiet >/dev/null 2>&1; then
            note "range deleted"
        else
            note "no reserved range to delete"
        fi
    else
        step "1-2/4 skipping peering teardown (disable_vpc_peering=true)"
    fi

    step "3/4 VPC network '${_network}'"
    if [ "${_create_network}" = "true" ]; then
        if gcloud compute networks delete "${_network}" \
             --project "${_project}" --quiet >/dev/null 2>&1; then
            note "network deleted"
        else
            note "network could not be deleted (other resources may still use it)"
        fi
    else
        note "network '${_network}' was not created here; leaving it in place"
    fi

    step "4/4 disabling ${APIGEE_TEARDOWN_APIS}"
    # NOT servicenetworking: see the header. --force is required because other
    # services declare a dependency on apigee, and without it this is a no-op
    # that reports success.
    # shellcheck disable=SC2086
    for api in ${APIGEE_TEARDOWN_APIS}; do
        if gcloud services disable "${api}" --project "${_project}" --force --quiet >/dev/null 2>&1; then
            note "disabled ${api}"
        else
            note "could not disable ${api} (may already be disabled)"
        fi
    done
    echo "Prerequisites removed."
}

case "${1:-}" in
    bootstrap) bootstrap ;;
    destroy)   destroy ;;
    *) echo "usage: $0 {bootstrap|destroy}" >&2; exit 2 ;;
esac
