#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# load-credentials.sh -- resolve the shared-org credential contract.
#
# Source this (do not execute it) from .test tasks that need live credentials:
#   . ./load-credentials.sh
#
# All three Apigee bundles are pointed at ONE shared Apigee X organization
# (an org is one-per-project, so the environment bundle provisions it and the
# others layer fixtures on top). They historically described that org three
# different ways, in two different files, which drifts silently. This resolves
# every accepted spelling into the variables the scripts here actually use.
#
# Canonical location:  .test/terraform/tf.secret   (matches the sibling bundles)
# Also accepted:       .test/tf.secret
#
# Accepted spellings of the organization, in precedence order:
#   APIGEE_ORG      bare name,             e.g. "my-org"
#   TF_VAR_org_id   resource-name form,    e.g. "organizations/my-org"
# and of the project:
#   GCP_PROJECT_ID, then TF_VAR_project_id
# and of the fixture suffix:
#   FIXTURE_SUFFIX, then TF_VAR_resource_suffix, else "test001"
#
# The "organizations/" prefix is stripped: the API paths these scripts build
# already carry that segment, so leaving it in produces
# organizations/organizations/<org>/... and 404s every call.
#
# Resolved in ONE place rather than per task: repeating it per task is how the
# spellings drifted apart in the first place.
#
# Exits non-zero when no credential file exists or the org cannot be determined.
# Printing a warning and returning 0 would tell the caller the credentials are
# present when they are not, and the live run that follows would validate
# nothing.
# -----------------------------------------------------------------------------

_lc_secret=""
for _lc_candidate in "terraform/tf.secret" "tf.secret"; do
  if [ -f "$_lc_candidate" ]; then
    _lc_secret="$_lc_candidate"
    break
  fi
done

if [ -z "$_lc_secret" ]; then
  echo "ERROR: no credential file found." >&2
  echo "       Expected .test/terraform/tf.secret (canonical) or .test/tf.secret." >&2
  echo "       See .test/README.md 'Manual prerequisites'." >&2
  exit 1
fi

if [ "$_lc_secret" = "tf.secret" ]; then
  echo "note: using .test/tf.secret; the sibling Apigee bundles expect .test/terraform/tf.secret" >&2
fi

# Remember anything already in the environment, then read the file into a clean
# slate so the two can be compared. An ambient value left over from another
# bundle's run still wins -- that is the usual contract -- but silently
# retargeting a shared organization is the exact drift this file exists to
# prevent, so a divergence is announced rather than assumed.
_lc_env_org="${APIGEE_ORG:-}"
_lc_env_project="${GCP_PROJECT_ID:-}"
_lc_env_suffix="${FIXTURE_SUFFIX:-}"
unset APIGEE_ORG GCP_PROJECT_ID FIXTURE_SUFFIX

set -a
# shellcheck disable=SC1090  # path is resolved above, not a literal
. "./$_lc_secret"
set +a

_lc_file_org="${APIGEE_ORG:-${TF_VAR_org_id:-}}"
_lc_file_project="${GCP_PROJECT_ID:-${TF_VAR_project_id:-}}"
_lc_file_suffix="${FIXTURE_SUFFIX:-${TF_VAR_resource_suffix:-}}"

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
FIXTURE_SUFFIX="${_lc_env_suffix:-${_lc_file_suffix:-test001}}"

if [ -z "$APIGEE_ORG" ]; then
  echo "ERROR: $_lc_secret sets neither APIGEE_ORG nor TF_VAR_org_id." >&2
  exit 1
fi
if [ -z "$GCP_PROJECT_ID" ]; then
  echo "ERROR: $_lc_secret sets neither GCP_PROJECT_ID nor TF_VAR_project_id." >&2
  exit 1
fi

export APIGEE_ORG GCP_PROJECT_ID FIXTURE_SUFFIX
echo "Using credentials from $_lc_secret (org: $APIGEE_ORG, project: $GCP_PROJECT_ID, suffix: $FIXTURE_SUFFIX)"
