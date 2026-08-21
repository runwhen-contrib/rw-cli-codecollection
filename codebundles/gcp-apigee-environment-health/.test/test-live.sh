#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Live issue-generation test for gcp-apigee-environment-health.
#
# Runs the runbook and SLI against the REAL provisioned fixtures and asserts on
# what they report, so "the suite ran" can never again be mistaken for "the
# checks work". Follows the pattern established by
# azure-devops-repository-health/.test/test-issue-generation.sh.
#
# Requires the fixtures from `task build-infra` (which now includes the keystore
# alias import). For a version that needs no cloud at all, see offline/run.sh.
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
# The SUBSTRATE suffix is resolved separately, with the same precedence chain
# apigee_prerequisites.sh uses. The two are usually equal, but they are not the
# same thing: this bundle's own fixtures (envgroups, target servers, keystore)
# are named from the per-run suffix, while the environments and the runtime
# instance are shared substrate named from APIGEE_SUBSTRATE_SUFFIX -- capped
# slots mean all five bundles must agree on it, so it survives a per-run suffix
# change. Deriving the environment name from SUFFIX made the assertion below
# look for an environment nobody had created the moment the two diverged.
SUBSTRATE_SUFFIX="${APIGEE_SUBSTRATE_SUFFIX:-${TF_VAR_resource_suffix:-${RESOURCE_SUFFIX:-test001}}}"
PROJECT="${TF_VAR_project_id:?TF_VAR_project_id must be set in tf.secret}"

echo "=== Apigee Environment Health -- Issue Generation Test ==="
echo "Project: ${PROJECT}   fixture suffix: ${SUFFIX}   substrate suffix: ${SUBSTRATE_SUFFIX}"
echo "APIGEE_ORG is left empty on purpose, to exercise org auto-discovery."
echo ""

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# The check scripts write their *_issues.json into the working directory, so
# run from a scratch dir and assert on those artifacts rather than scraping
# log.html -- the JSON is the actual contract between scripts and robot.
RUN_DIR="${OUTPUT_DIR}/run"
mkdir -p "${RUN_DIR}"

# ...but RW.CLI resolves each script RELATIVE TO THE WORKING DIRECTORY, so a
# scratch dir with no scripts in it fails every task before any of them runs:
#
#   [ WARN ] File 'discover_topology.sh' not found in '.../run'
#   FileNotFoundError: Could not find the robot file in any known locations.
#   7 tasks, 0 passed, 7 failed
#
# The sibling this script was modelled on sidesteps it by running robot from the
# bundle root (`cd ../..`), which resolves the scripts but drops every
# *_issues.json into the source tree. Seeding copies keeps both properties: the
# scripts resolve, and the artifacts still land somewhere disposable. This is
# what gcp-apigee-proxy-health's offline harness already does per scenario.
cp "${BUNDLE}"/*.sh "${RUN_DIR}"/ 2>/dev/null || true

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

# bodies -- title + details + actual, joined.
#
# Assertions about a RESOURCE NAME must look here, never at titles(). Titles
# deliberately carry the failure mode and the org scope only; the offline tier
# asserts that directly ("no contained resource name in any title"), because one
# issue aggregates every affected resource and a title naming one of them is
# both wrong and unstable across runs. The names live in details.
#
# Every known-positive below used titles() and so reported a fixture as
# undetected when the check had found it correctly. The known-NEGATIVES used
# titles() too, which was worse: a healthy fixture's name can never appear in a
# title, so those assertions passed without testing anything at all.
bodies() { [ -f "$1" ] && jq -r '[.[] | .title, .details, .actual] | join(" ")' "$1" 2>/dev/null || echo ""; }

echo "=== Discovery ==="
assert_eq "topology dump written"      "$([ -f apigee_topology.json ] && echo yes || echo no)" "yes"
assert_eq "org auto-discovered"        "$(jq -r '.org.name // ""' apigee_topology.json 2>/dev/null)" "${PROJECT}"
assert_eq "discovery reported no issues" "$(count discovery_issues.json)" "0"
# ${x:-0} guards the arithmetic: when the topology is absent jq prints nothing,
# and `[ -ge 2 ]` with an empty left side is a syntax error, not a failed
# assertion -- which is how a missing dump surfaced as a bash error mixed into
# the results instead of as this check failing.
assert_eq "environments discovered"    "$([ "$(jq '.environments | length' apigee_topology.json 2>/dev/null || echo 0)" -ge 2 ] 2>/dev/null && echo ok || echo no)" "ok"
assert_eq "org network resolved"       "$([ -n "$(jq -r '.org.network // ""' apigee_topology.json 2>/dev/null)" ] && echo ok || echo no)" "ok"

echo ""
echo "=== Known-positive: every seeded fixture must be reported ==="
assert_has "unattached environment"   "$(bodies instance_attachment_issues.json)" "apigee-env-unattached-${SUBSTRATE_SUFFIX}"
assert_has "orphan envgroup"          "$(bodies envgroup_attachment_issues.json)" "apigee-group-orphan-${SUFFIX}"
assert_has "disabled target server"   "$(bodies target_server_issues.json)"       "apigee-ts-disabled-${SUFFIX}"
assert_has "dangling target server"   "$(bodies target_server_issues.json)"       "apigee-ts-dangling-${SUFFIX}"
assert_eq  "expiring keystore cert"   "$([ "$(count keystore_cert_issues.json)" -ge 1 ] && echo ok || echo no)" "ok"

echo ""
echo "=== Known-negative: healthy fixtures must NOT be reported ==="
assert_hasnt "healthy envgroup not flagged"   "$(bodies envgroup_attachment_issues.json)" "apigee-group-healthy-${SUFFIX}"
assert_hasnt "healthy target not flagged"     "$(bodies target_server_issues.json)"       "apigee-ts-healthy-${SUFFIX}"
assert_eq    "org and environments ACTIVE"    "$(count org_env_state_issues.json)" "0"
assert_eq    "southbound clean"               "$(count southbound_issues.json)" "0"

echo ""
echo "=== Not blind ==="
# This bundle is runbook-only; there is no score to sanity-check. The guard the
# score used to provide -- "a clean result here means the run never read the
# topology" -- still applies, so assert it directly against the artifacts: the
# fixtures are deliberately broken, so a run that raises nothing at all has not
# looked at anything.
total_issues=0
for f in org_env_state instance_attachment envgroup_attachment keystore_cert \
         target_server capacity southbound; do
    c="$(count "${f}_issues.json")"
    [ "${c}" -gt 0 ] && total_issues=$((total_issues + c))
done
echo "  issues raised across all checks: ${total_issues}"
assert_eq "run is not blind (broken fixtures produced findings)" \
    "$([ "${total_issues}" -gt 0 ] && echo ok || echo blind)" "ok"
assert_eq "every check wrote a result file" \
    "$(for f in org_env_state instance_attachment envgroup_attachment keystore_cert target_server capacity southbound; do
         [ "$(count "${f}_issues.json")" -lt 0 ] && echo missing; done | wc -l | xargs)" "0"

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
