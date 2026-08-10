#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Live issue-generation test for gcp-apigee-environment-health.
#
# Runs the runbook and SLI against the REAL provisioned fixtures and asserts on
# what they report, so "the suite ran" can never again be mistaken for "the
# checks work". Follows the pattern established by
# azure-devops-repository-health/.test/test-issue-generation.sh.
#
# Requires the fixtures from `task build-infra` and `task import-keystore-alias`
# to already exist. For a version that needs no cloud at all, see offline/run.sh.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${HERE}/.." && pwd)"
OUTPUT_DIR="${HERE}/output/issue-generation-test"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; DIM=$'\033[2m'; NC=$'\033[0m'
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "${GREEN}" "${NC}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "${RED}" "${NC}" "$1"; }
assert_has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 ${DIM}(missing '$3')${NC}" ;; esac; }
assert_hasnt() { case "$2" in *"$3"*) bad "$1 ${DIM}(unexpectedly found '$3')${NC}" ;; *) ok "$1" ;; esac; }
assert_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 ${DIM}(expected '$3', got '$2')${NC}"; fi; }

if [ ! -f "${HERE}/terraform/tf.secret" ] || [ ! -f "${HERE}/gcp.json.secret" ]; then
    echo "${RED}Credentials required: terraform/tf.secret and gcp.json.secret.${NC}"
    echo "This test runs against real provisioned fixtures. For a credential-free"
    echo "run of the same check logic, use: task test-offline"
    exit 1
fi

# shellcheck disable=SC1091
source "${HERE}/terraform/tf.secret"
SUFFIX="${TF_VAR_resource_suffix:-${RESOURCE_SUFFIX:-test001}}"
PROJECT="${TF_VAR_project_id:?TF_VAR_project_id must be set in tf.secret}"

echo "=== Apigee Environment Health -- Issue Generation Test ==="
echo "Project: ${PROJECT}   suffix: ${SUFFIX}"
echo "APIGEE_ORG is left empty on purpose, to exercise org auto-discovery."
echo ""

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# The check scripts write their *_issues.json into the working directory, so
# run from a scratch dir and assert on those artifacts rather than scraping
# log.html -- the JSON is the actual contract between scripts and robot.
RUN_DIR="${OUTPUT_DIR}/run"
mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}" || exit 1

printf '%sRunning runbook against live fixtures...%s\n' "${BLUE}" "${NC}"
robot \
    --outputdir "${OUTPUT_DIR}" \
    --variable GCP_PROJECT_ID:"${PROJECT}" \
    --variable APIGEE_ORG: \
    --variable ENVIRONMENTS:All \
    "${BUNDLE}/runbook.robot" > "${OUTPUT_DIR}/runbook.stdout" 2>&1
ROBOT_RC=$?
echo "  robot exit: ${ROBOT_RC}  (log: ${OUTPUT_DIR}/log.html)"
echo ""

if [ ! -f "${OUTPUT_DIR}/output.xml" ]; then
    printf '%s✗ Robot produced no output.xml -- the suite did not run.%s\n' "${RED}" "${NC}"
    tail -30 "${OUTPUT_DIR}/runbook.stdout" 2>/dev/null
    exit 1
fi

titles() { [ -f "$1" ] && jq -r '[.[].title] | join(" | ")' "$1" 2>/dev/null || echo ""; }
count()  { [ -f "$1" ] && jq 'length' "$1" 2>/dev/null || echo -1; }

echo "=== Discovery ==="
assert_eq "topology dump written"      "$([ -f apigee_topology.json ] && echo yes || echo no)" "yes"
assert_eq "org auto-discovered"        "$(jq -r '.org.name // ""' apigee_topology.json 2>/dev/null)" "${PROJECT}"
assert_eq "discovery reported no issues" "$(count discovery_issues.json)" "0"
assert_eq "environments discovered"    "$([ "$(jq '.environments | length' apigee_topology.json 2>/dev/null)" -ge 2 ] && echo ok || echo no)" "ok"
assert_eq "org network resolved"       "$([ -n "$(jq -r '.org.network // ""' apigee_topology.json 2>/dev/null)" ] && echo ok || echo no)" "ok"

echo ""
echo "=== Known-positive: every seeded fixture must be reported ==="
assert_has "unattached environment"   "$(titles instance_attachment_issues.json)" "apigee-env-unattached-${SUFFIX}"
assert_has "orphan envgroup"          "$(titles envgroup_attachment_issues.json)" "apigee-group-orphan-${SUFFIX}"
assert_has "disabled target server"   "$(titles target_server_issues.json)"       "apigee-ts-disabled-${SUFFIX}"
assert_has "dangling target server"   "$(titles target_server_issues.json)"       "apigee-ts-dangling-${SUFFIX}"
assert_eq  "expiring keystore cert"   "$([ "$(count keystore_cert_issues.json)" -ge 1 ] && echo ok || echo no)" "ok"

echo ""
echo "=== Known-negative: healthy fixtures must NOT be reported ==="
assert_hasnt "healthy envgroup not flagged"   "$(titles envgroup_attachment_issues.json)" "apigee-group-healthy-${SUFFIX}"
assert_hasnt "healthy target not flagged"     "$(titles target_server_issues.json)"       "apigee-ts-healthy-${SUFFIX}"
assert_eq    "org and environments ACTIVE"    "$(count org_env_state_issues.json)" "0"
assert_eq    "southbound clean"               "$(count southbound_issues.json)" "0"

echo ""
printf '%sRunning SLI...%s\n' "${BLUE}" "${NC}"
robot \
    --outputdir "${OUTPUT_DIR}/sli" \
    --variable GCP_PROJECT_ID:"${PROJECT}" \
    --variable APIGEE_ORG: \
    --variable ENVIRONMENTS:All \
    "${BUNDLE}/sli.robot" > "${OUTPUT_DIR}/sli.stdout" 2>&1

SCORE_LINE=$(grep -ho 'Apigee Health Score: [0-9.]*' "${OUTPUT_DIR}/sli.stdout" \
             "${OUTPUT_DIR}/sli/log.html" 2>/dev/null | head -1)
SCORE="${SCORE_LINE##*: }"
echo "  ${SCORE_LINE:-<no score found>}"
echo ""
echo "=== SLI scoring ==="
if [ -z "${SCORE}" ]; then
    bad "health score not found in SLI output"
else
    # The fixtures are deliberately broken, so a perfect score means the SLI is
    # scoring a topology it did not actually read -- the original defect.
    assert_eq "score is not a blind 1.0" "$([ "${SCORE}" = "1.0" ] || [ "${SCORE}" = "1" ] && echo blind || echo ok)" "ok"
    assert_eq "score is not 0 (discovery worked)" "$([ "${SCORE}" = "0.0" ] || [ "${SCORE}" = "0" ] && echo dead || echo ok)" "ok"
fi

echo ""
echo "==============================================="
printf '  %s%d passed%s, %s%d failed%s\n' "${GREEN}" "${PASS}" "${NC}" \
    "$([ "${FAIL}" -gt 0 ] && echo "${RED}" || echo "${GREEN}")" "${FAIL}" "${NC}"
if [ "${FAIL}" -gt 0 ]; then
    printf '  %s✗ Issue generation test FAILED%s\n' "${RED}" "${NC}"
    printf '  artifacts: %s\n' "${OUTPUT_DIR}"
    exit 1
fi
printf '  %s✓ Issue generation test PASSED%s\n' "${GREEN}" "${NC}"
