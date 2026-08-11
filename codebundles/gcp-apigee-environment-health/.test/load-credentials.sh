#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# load-credentials.sh -- resolve the shared-org credential contract.
#
# Source this (do not execute it) from .test tasks that need live credentials:
#   . ./load-credentials.sh
#
# All three Apigee bundles are pointed at ONE shared Apigee X organization
# (an org is one-per-project, so this bundle provisions it and the others layer
# fixtures on top). They historically described that org three different ways,
# in two different files, which drifts silently. This resolves every accepted
# spelling into the variables the scripts here actually use.
#
# Canonical location:  .test/terraform/tf.secret
# Also accepted:       .test/tf.secret
#
# Paths are resolved by locating this script, not from the caller's working
# directory, because some tasks in this bundle run with `dir: terraform`. That
# is the only deviation from the sibling implementation, and it is required for
# the same contract to hold from both locations.
#
# It must not use BASH_SOURCE to do so: go-task runs commands through
# mvdan.cc/sh, where that variable does not exist. See the probe below.
#
# Accepted spellings of the organization, in precedence order:
#   APIGEE_ORG      bare name,          e.g. "my-org"
#   TF_VAR_org_id   resource-name form, e.g. "organizations/my-org"
# and of the project:
#   GCP_PROJECT_ID, then TF_VAR_project_id
#
# The "organizations/" prefix is stripped: the API paths built here already
# carry that segment, so leaving it in produces
# organizations/organizations/<org>/... and 404s every call.
#
# Exits non-zero when no credential file exists or the org cannot be determined.
# Printing a warning and returning 0 would tell the caller the credentials are
# present when they are not, and the live run that follows would validate
# nothing.
# -----------------------------------------------------------------------------

# Locate the .test directory WITHOUT BASH_SOURCE. go-task runs commands through
# an embedded POSIX shell (mvdan.cc/sh) where BASH_SOURCE is unset, so
# `dirname "${BASH_SOURCE[0]}"` evaluates to "." and silently resolves to the
# caller's working directory instead of this script's. Tasks declaring
# `dir: terraform` then search one level too deep -- looking for
# terraform/terraform/tf.secret -- so the documented .test/tf.secret fallback
# never resolves, and the canonical file is found as the second candidate,
# which used to trip the "using .test/tf.secret" note. Probe for this script
# instead: it works under any POSIX shell and from either directory.
_lc_here=""
for _lc_root in "." ".."; do
  if [ -f "${_lc_root}/load-credentials.sh" ]; then
    _lc_here="$(cd "$_lc_root" && pwd)"
    break
  fi
done
if [ -z "$_lc_here" ]; then
  echo "ERROR: cannot locate the .test directory containing load-credentials.sh." >&2
  echo "       Run this from .test or from a task declaring dir: terraform." >&2
  exit 1
fi

_lc_secret=""
for _lc_candidate in "${_lc_here}/terraform/tf.secret" "${_lc_here}/tf.secret"; do
  if [ -f "$_lc_candidate" ]; then
    _lc_secret="$_lc_candidate"
    break
  fi
done

if [ -z "$_lc_secret" ]; then
  echo "ERROR: no credential file found." >&2
  echo "       Expected ${_lc_here}/terraform/tf.secret (canonical)" >&2
  echo "       or ${_lc_here}/tf.secret." >&2
  echo "       See .test/README.md 'Prerequisites'. For a run that needs no" >&2
  echo "       credentials at all, use: task test-offline" >&2
  exit 1
fi

# Print the path actually resolved, never a hardcoded one: the previous version
# asserted ".test/tf.secret" while the error below named the real file, so the
# two messages could contradict each other.
if [ "$_lc_secret" != "${_lc_here}/terraform/tf.secret" ]; then
  echo "note: using ${_lc_secret}; the sibling Apigee bundles expect ${_lc_here}/terraform/tf.secret" >&2
fi

# Remember anything already in the environment, then read the file into a clean
# slate so the two can be compared. An ambient value left over from another
# bundle's run still wins -- that is the usual contract -- but silently
# retargeting a shared organization is the exact drift this file exists to
# prevent, so a divergence is announced rather than assumed.
_lc_env_org="${APIGEE_ORG:-}"
_lc_env_project="${GCP_PROJECT_ID:-}"
unset APIGEE_ORG GCP_PROJECT_ID

set -a
# shellcheck disable=SC1090  # path is resolved above, not a literal
. "$_lc_secret"
set +a

_lc_file_org="${APIGEE_ORG:-${TF_VAR_org_id:-}}"
_lc_file_project="${GCP_PROJECT_ID:-${TF_VAR_project_id:-}}"

# Compare in normalised form so "organizations/x" and "x" are not reported as a
# conflict -- they name the same organization.
_lc_env_org="${_lc_env_org#organizations/}"
_lc_file_org="${_lc_file_org#organizations/}"

if [ -n "$_lc_env_org" ] && [ -n "$_lc_file_org" ] && [ "$_lc_env_org" != "$_lc_file_org" ]; then
  echo "WARNING: APIGEE_ORG is already set to '$_lc_env_org' in the environment," >&2
  echo "         but $_lc_secret names '$_lc_file_org'. Using the environment value." >&2
fi
if [ -n "$_lc_env_project" ] && [ -n "$_lc_file_project" ] && [ "$_lc_env_project" != "$_lc_file_project" ]; then
  echo "WARNING: GCP_PROJECT_ID is already set to '$_lc_env_project' in the environment," >&2
  echo "         but $_lc_secret names '$_lc_file_project'. Using the environment value." >&2
fi

APIGEE_ORG="${_lc_env_org:-$_lc_file_org}"
GCP_PROJECT_ID="${_lc_env_project:-$_lc_file_project}"

if [ -z "$APIGEE_ORG" ]; then
  echo "ERROR: $_lc_secret sets neither APIGEE_ORG nor TF_VAR_org_id." >&2
  exit 1
fi
if [ -z "$GCP_PROJECT_ID" ]; then
  echo "ERROR: $_lc_secret sets neither GCP_PROJECT_ID nor TF_VAR_project_id." >&2
  exit 1
fi

# Terraform in this bundle expects the resource-name form; the REST paths expect
# the bare name. Export both so callers never re-derive one from the other.
TF_VAR_org_id="organizations/${APIGEE_ORG}"
TF_VAR_project_id="${GCP_PROJECT_ID}"

export APIGEE_ORG GCP_PROJECT_ID TF_VAR_org_id TF_VAR_project_id
echo "Using credentials from ${_lc_secret#"${_lc_here}"/} (org: $APIGEE_ORG, project: $GCP_PROJECT_ID)"
