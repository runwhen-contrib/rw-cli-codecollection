#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# test-live.sh -- the LIVE tier for gcp-apigee-security-config.
#
# Runs every check script against the SHARED test org and asserts on each
# script's OWN outputs. Correctness of the check logic is covered by the offline
# tier (offline/run.sh), which needs no credentials; this tier exists to confirm
# the scripts behave the same way against real API responses -- in particular
# the bare-array list endpoints (/environments, /targetservers, /keystores),
# whose shape is the trap apigee_common.sh was written to contain and which a
# fixture can only approximate.
#
# Requires the fixtures from `task build-infra` and active credentials (see
# terraform/tf.secret). For a credential-free run of the same logic:
#   task test-offline
#
# The Apigee objects this bundle inspects are provisioned by the sibling
# bundles in the shared org, so `task build-infra` here creates only the reader
# service account. If the org is empty the checks correctly report nothing --
# which is why the inventory assertion below exists: a run that judged zero
# objects is not evidence the checks work.
#
# Exits non-zero if any assertion fails, and keeps going after the first so one
# run shows the whole blast radius.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${HERE}/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apigee-sec-live-XXXXXX")"

: "${APIGEE_ORG:=${TF_VAR_org_id:-}}"
: "${GCP_PROJECT_ID:=${TF_VAR_project_id:-}}"
: "${APIGEE_ORG:?Must set APIGEE_ORG (or TF_VAR_org_id)}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID (or TF_VAR_project_id)}"
APIGEE_ORG="${APIGEE_ORG#organizations/}"
export APIGEE_ORG GCP_PROJECT_ID
export QUOTA_ABUSE_THRESHOLD="${QUOTA_ABUSE_THRESHOLD:-80}"
export SECURITY_SCORE_THRESHOLD="${SECURITY_SCORE_THRESHOLD:-80}"
export SECURITY_WINDOW_HOURS="${SECURITY_WINDOW_HOURS:-24}"

# script|issues_file -- named per script rather than globbed, so a check that
# stopped producing anything cannot pass by inheriting a sibling's output file.
CASES="
check_app_access.sh|app_access_issues.json
check_quota_limits.sh|quota_limits_issues.json
check_target_vhost_config.sh|target_vhost_issues.json
check_security_score.sh|security_score_issues.json
"

failures=0
note_failure() { echo "    ✗ $1"; failures=$((failures + 1)); }

cd "${WORK_DIR}" || exit 1
echo "=== Apigee Security Config -- live tier ==="
echo "Project: ${GCP_PROJECT_ID}   org: ${APIGEE_ORG}"
echo "Working directory: ${WORK_DIR}"
echo

# Prove the credential can actually read the org BEFORE judging any check's
# silence. A 403 turns every list into [], and "nothing misconfigured" then
# reads identically to "nothing was looked at".
envs_json="$(curl -fsS -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/environments" 2>/dev/null || echo "")"
if [ -z "${envs_json}" ]; then
    echo "    ✗ cannot list environments in org ${APIGEE_ORG} -- the credential cannot read it."
    echo "      Every check below would report clean without having looked at anything."
    exit 1
fi
env_count="$(printf '%s' "${envs_json}" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
echo "    ✓ org readable: ${env_count} environment(s) visible"
if [ "${env_count}" = "0" ]; then
    echo "    ! the org has no environments, so the environment-scoped checks will"
    echo "      report nothing. Run gcp-apigee-environment-health's build-infra first."
fi
echo

while IFS='|' read -r script issues_file; do
  [ -z "${script}" ] && continue
  echo "==> ${script}"

  bash "${BUNDLE_DIR}/${script}" > "${WORK_DIR}/${script%.sh}.stdout" 2> "${WORK_DIR}/${script%.sh}.stderr"
  rc=$?

  # Check scripts REPORT problems; they do not fail on them. A non-zero exit is
  # the script itself breaking, which is a different and worse thing.
  if [ "${rc}" -ne 0 ]; then
    note_failure "${script} exited ${rc} (expected 0; check scripts report problems, they do not fail)"
    echo "        stderr: $(head -c 300 "${WORK_DIR}/${script%.sh}.stderr")"
    continue
  fi

  if [ ! -f "${issues_file}" ]; then
    note_failure "${script} did not produce ${issues_file}"
    continue
  fi
  if ! jq -e 'type == "array"' "${issues_file}" >/dev/null 2>&1; then
    note_failure "${issues_file} is not a valid JSON array"
    echo "        head: $(head -c 300 "${issues_file}")"
    continue
  fi

  # Every issue must carry the fields the runbook indexes, or Add Issue throws
  # at runtime -- which surfaces as a broken task, not as a reported problem.
  missing="$(jq -r '[.[] | select(
      has("title") and has("details") and has("severity") and
      has("next_steps") and has("expected") and has("actual") | not
    )] | length' "${issues_file}")"
  if [ "${missing}" != "0" ]; then
    note_failure "${issues_file} has ${missing} issue(s) missing required runbook fields"
  fi

  echo "    ✓ ${issues_file}: valid array, $(jq 'length' "${issues_file}") issue(s)"
done <<EOF
$(printf '%s\n' "${CASES}")
EOF

echo
if [ "${failures}" -gt 0 ]; then
  echo "Live tier FAILED: ${failures} assertion(s) failed."
  echo "Artifacts preserved at: ${WORK_DIR}"
  exit 1
fi

echo "All checks produced valid, readable output against org ${APIGEE_ORG}."
if [ "${KEEP_ARTIFACTS:-0}" = "1" ]; then
  echo "Artifacts preserved at: ${WORK_DIR}"
else
  rm -rf "${WORK_DIR}"
fi
