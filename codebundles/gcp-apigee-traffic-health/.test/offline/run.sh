#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Offline assertion tier for gcp-apigee-traffic-health.
#
# Runs every bundle script against canned data -- no cloud, no credentials, no
# spend -- and ASSERTS on what it reports. Exits non-zero if any assertion
# fails, so it can gate a PR.
#
# Two kinds of canned data are used, and the difference matters:
#
#   .test/offline/fixtures/  Apigee Management API responses, whose shapes come
#                            from the v1 discovery document (see fixtures.sh).
#                            These drive discover_metrics_scope.sh, the only
#                            script here that talks to the Apigee API.
#   .test/mock/              Cloud Monitoring aggregates in the bundle's own
#                            MOCK_DATA_FILE format. There is no API shape to get
#                            wrong in these; they exercise threshold and
#                            aggregation logic.
#
# It cannot catch anything that depends on real API behaviour not encoded in the
# fixtures; it complements a live run, it does not replace it.
#
#   ./run.sh          run every scenario
#   ./run.sh -v       also echo each script's stdout on failure
# -----------------------------------------------------------------------------
set -uo pipefail

# --- HERMETIC: this tier must not inherit the caller's credentials -----------
#
# "No cloud, no credentials, no spend" has to mean the tier cannot SEE the
# caller's credentials, not merely that it does not ask for them.
#
# load-credentials.sh ends with
#     export APIGEE_ORG GCP_PROJECT_ID TF_VAR_org_id TF_VAR_project_id
# and tf.secret itself is a file of `export TF_VAR_...` lines. Sourcing either
# -- which is the documented way to get credentials, and what every live task
# does -- leaves those set for the rest of the shell session. Every later run of
# this tier in that shell then reads a REAL organization where a fixture was
# intended, and assertions start passing or failing according to whose terminal
# they ran in.
#
# That is not hypothetical: with TF_VAR_org_id exported, the credential-contract
# scenario below stops failing on a tf.secret that names no org (it silently
# inherits one), and product-governance's org-resolution scenarios resolve the
# ambient org instead of the fixture's.
#
# Unset here, once, before any scenario runs. Scenarios export what they need.
unset APIGEE_ORG GCP_PROJECT_ID \
      TF_VAR_org_id TF_VAR_project_id TF_VAR_resource_suffix \
      RESOURCE_SUFFIX APIGEE_SUBSTRATE_SUFFIX FIXTURE_SUFFIX \
      APIGEE_TOKEN GCP_ACCESS_TOKEN GOOGLE_APPLICATION_CREDENTIALS \
      APIGEE_TEST_ENV APIGEE_ORG_ID 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${HERE}/../.." && pwd)"
MOCK="${BUNDLE}/.test/mock"
WORK="${HERE}/.work"
VERBOSE="${1:-}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; DIM=$'\033[2m'; NC=$'\033[0m'
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '    %sPASS%s %s\n' "${GREEN}" "${NC}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %sFAIL%s %s\n' "${RED}" "${NC}" "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 ${DIM}(expected '$3', got '$2')${NC}"; fi
}
assert_has() {
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 ${DIM}(missing '$3')${NC}" ;; esac
}
assert_hasnt() {
    case "$2" in *"$3"*) bad "$1 ${DIM}(unexpectedly found '$3')${NC}" ;; *) ok "$1" ;; esac
}

CHECKS="check_error_rates check_latency check_throughput check_target_performance"

# The MOCK_DATA_FILE each check reads, by script name.
mockfile_for() {
    case "$1" in
        check_error_rates)        echo "error.json" ;;
        check_latency)            echo "latency.json" ;;
        check_throughput)         echo "throughput.json" ;;
        check_target_performance) echo "target.json" ;;
    esac
}
# The issues file each check writes, by script name.
issuefile_for() {
    case "$1" in
        check_error_rates)        echo "error_rate_issues.json" ;;
        check_latency)            echo "latency_issues.json" ;;
        check_throughput)         echo "throughput_issues.json" ;;
        check_target_performance) echo "target_performance_issues.json" ;;
    esac
}

# issues <file> -- issue count, or -1 when the file is missing entirely
issues() { [ -f "$1" ] && jq 'length' "$1" 2>/dev/null || echo -1; }
titles() { [ -f "$1" ] && jq -r '[.[].title] | join(" | ")' "$1" 2>/dev/null || echo ""; }
# Whole issue body -- titles are failure-mode only, so anything asserting on a
# resource name has to look at details/actual as well.
bodies() { [ -f "$1" ] && jq -r '[.[] | .title, .actual, .details] | join(" ")' "$1" 2>/dev/null || echo ""; }

# mock_scenario <name> -- runs every check against .test/mock/<name>
mock_scenario() {
    local name="$1"
    printf '\n%s== mock scenario: %s%s\n' "${BLUE}" "${name}" "${NC}"
    rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
    export PATH="${HERE}/bin:${PATH}"
    export GCP_PROJECT_ID="mock-project"
    export APIGEE_ORG="mock-org"
    export ERROR_RATE_THRESHOLD=5
    export LATENCY_MS_THRESHOLD=500
    export METRIC_WINDOW_MIN=60
    export THROUGHPUT_DEVIATION_PCT=200
    unset FIXTURES
    for s in ${CHECKS}; do
        MOCK_DATA_FILE="${MOCK}/${name}/$(mockfile_for "${s}")" \
            bash "${BUNDLE}/${s}.sh" > "${s}.log" 2>&1
        eval "RC_${s}=\$?"
    done
}
rc() { eval "echo \"\${RC_$1}\""; }

# =============================================================================
# Discovery against real Apigee API SHAPES. This is the tier's only contact with
# the Apigee API, and the only place a response-shape defect can be caught.
printf '\n%s== Scenario A -- discovery against discovery-document shapes%s\n' "${BLUE}" "${NC}"
bash "${HERE}/fixtures.sh" "${HERE}/fixtures/main" >/dev/null
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
export PATH="${HERE}/bin:${PATH}"
export FIXTURES="${HERE}/fixtures/main"
export GCP_PROJECT_ID="mock-project" APIGEE_ORG="mock-org"
unset MOCK_DATA_FILE
bash "${BUNDLE}/discover_metrics_scope.sh" > discover.log 2>&1
DISCOVER_RC=$?

assert_eq "discovery exits 0" "${DISCOVER_RC}" "0"
assert_eq "discovery reported no issues" "$(issues discovery_issues.json)" "0"
assert_eq "org recorded in the scope" \
    "$(jq -r '.organization' apigee_scope.json)" "mock-org"
# /apis is the documented object response.
assert_eq "proxies read from the documented ListApiProxiesResponse" \
    "$(jq -r '.proxies | length' apigee_scope.json)" "3"
# /environments returns a BARE ARRAY; reading it as an object yields nothing.
assert_eq "environments read as the bare array the API returns" \
    "$(jq -rc '.environments' apigee_scope.json)" '["prod","staging"]'
# The defect this fixture set exists for: targetservers is ALSO a bare array of
# strings, so `.targetServers[].name` matched nothing and every target server
# silently vanished from the scope. The target performance check then evaluated
# an empty list and rendered as passed.
assert_eq "target servers read as the bare array the API returns" \
    "$(jq -r '.target_servers | length' apigee_scope.json)" "2"
assert_eq "target servers carry their environment" \
    "$(jq -r '.target_servers[0].environment' apigee_scope.json)" "prod"

# =============================================================================
# Failure to determine must NOT look like a positive determination of absence.
printf '\n%s== Scenario B -- no token (could NOT determine)%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
export FIXTURES="${HERE}/fixtures/main" GCP_PROJECT_ID="mock-project" APIGEE_ORG="mock-org"
GCLOUD_NO_TOKEN=1 bash "${BUNDLE}/discover_metrics_scope.sh" > discover.log 2>&1
assert_eq  "discovery raises exactly one issue" "$(issues discovery_issues.json)" "1"
assert_has "and says it could not authenticate" \
    "$(titles discovery_issues.json)" "Cannot authenticate to Apigee in org"

# An org that could not be identified at all is the ONE case where the project is
# the right identifier: the org is precisely what is missing.
printf '\n%s== Scenario C -- APIGEE_ORG empty (org unknown)%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
export FIXTURES="${HERE}/fixtures/main" GCP_PROJECT_ID="mock-project"
APIGEE_ORG="" bash "${BUNDLE}/discover_metrics_scope.sh" > discover.log 2>&1
assert_eq  "discovery raises exactly one issue" "$(issues discovery_issues.json)" "1"
# Single quotes are load-bearing: the backticks are literal text in the issue
# title, not a command substitution. SC2016 is exactly backwards here.
# shellcheck disable=SC2016
assert_has "and names the project, the only identifier it has" \
    "$(titles discovery_issues.json)" 'in project `mock-project`'

# =============================================================================
# Missing scope file is an ERROR, not an empty org. Discovery runs in Suite
# Initialization and fails the suite when it cannot produce a scope, so a check
# that finds no file has been run against nothing and must say so rather than
# reporting "no issues found".
printf '\n%s== Scenario D -- scope file absent (must error, not report clean)%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
export PATH="${HERE}/bin:${PATH}"
export GCP_PROJECT_ID="mock-project" APIGEE_ORG="mock-org"
unset MOCK_DATA_FILE
for s in ${CHECKS}; do
    bash "${BUNDLE}/${s}.sh" > "${s}.log" 2>&1
    rc_missing=$?
    assert_eq "${s} exits non-zero" \
        "$([ "${rc_missing}" -ne 0 ] && echo error || echo clean)" "error"
    assert_eq "${s} wrote no misleading empty result" \
        "$([ -f "$(issuefile_for "${s}")" ] && echo wrote || echo none)" "none"
done

# An empty scope, on the other hand, IS a positive determination of absence and
# must not be reported as a fault.
printf '\n%s== Scenario E -- org genuinely has nothing (absence is not a finding)%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
echo '{"organization":"mock-org","project":"mock-project","proxies":[],"environments":[],"target_servers":[]}' > apigee_scope.json
for s in ${CHECKS}; do
    bash "${BUNDLE}/${s}.sh" > "${s}.log" 2>&1
    assert_eq "${s} exits 0" "$?" "0"
    assert_eq "${s} reports no issue" "$(issues "$(issuefile_for "${s}")")" "0"
done

# =============================================================================
mock_scenario "healthy"
for s in ${CHECKS}; do assert_eq "${s} exits 0" "$(rc "${s}")" "0"; done
for s in ${CHECKS}; do
    assert_eq "${s} finds nothing in a healthy org" "$(issues "$(issuefile_for "${s}")")" "0"
done

mock_scenario "high_error"
assert_eq  "error rates flagged"      "$(issues error_rate_issues.json)" "1"
assert_eq  "latency clean"            "$(issues latency_issues.json)" "0"
assert_eq  "throughput clean"         "$(issues throughput_issues.json)" "0"
assert_eq  "target performance clean" "$(issues target_performance_issues.json)" "0"
assert_has "the offending proxy is named in the body, not the title" \
    "$(bodies error_rate_issues.json)" "payments-api"

mock_scenario "latency_target"
assert_eq "error rates clean"      "$(issues error_rate_issues.json)" "0"
assert_eq "latency flagged"        "$(issues latency_issues.json)" "1"
assert_eq "target performance flagged" "$(issues target_performance_issues.json)" "1"

# =============================================================================
# The aggregation contract. Several failing proxies in one run is ONE issue whose
# details list them, not one issue each -- otherwise a bad deploy opens an issue
# per proxy and closes them all on the next run.
mock_scenario "multi_offender"
assert_eq "three proxies over the error threshold still raise ONE issue" \
    "$(issues error_rate_issues.json)" "1"
assert_eq "two proxies over the latency threshold still raise ONE issue" \
    "$(issues latency_issues.json)" "1"
assert_eq "two degraded targets raise ONE issue per failure mode, not per target" \
    "$(issues target_performance_issues.json)" "2"
assert_eq "anomalies and deviation are separate failure modes" \
    "$(issues throughput_issues.json)" "2"

printf '  %severy offender is still named, in the body%s\n' "${DIM}" "${NC}"
for n in payments-api orders-api; do
    assert_has "error issue lists ${n}" "$(bodies error_rate_issues.json)" "${n}"
done
assert_hasnt "and the healthy proxy is not listed" \
    "$(bodies error_rate_issues.json)" "catalog-api"

# A traffic collapse is the single most important throughput signal, and a
# signed-percentage comparison could never report it: a drop is bounded at
# -100%, so abs(deviation) > 200 only ever fired on a spike.
#
# Read from the DEVIATION issue specifically, not from the whole file. `prod`
# also appears in the anomaly issue, so asserting against every body passed
# whether or not the deviation mode fired at all -- an assertion that could not
# fail, which mutation testing is what caught.
DEVIATION_BODY="$(jq -r '[.[] | select(.title | test("changed sharply")) | .details, .actual] | join(" ")' \
    throughput_issues.json 2>/dev/null || echo "")"
assert_has "a collapse in traffic is reported, not only a spike" \
    "${DEVIATION_BODY}" "prod"
assert_has "  ...and a spike is reported too" \
    "${DEVIATION_BODY}" "staging"

printf '  %sissue titles: failure mode + org scope only%s\n' "${DIM}" "${NC}"
# A title may name the SLX's own scope -- there is exactly one org per SLX and it
# never changes, so it costs no churn and tells an operator which SLX fired. It
# must NOT name a CONTAINED resource, of which there are many and which come and
# go, nor any changing number.
#
# The org is stripped before the checks below so it does not count as a contained
# resource name; it is stripped only where backticked, so an unquoted mention
# would still trip the guard.
strip_scope() {
    jq -r '[.[].title
            | gsub(" in org `[^`]*`"; "")
            | gsub("`mock-org`"; "")
            | gsub(" in project `[^`]*`"; "")]'
}
for f in error_rate latency throughput target_performance; do
    [ -f "${f}_issues.json" ] || continue
    assert_eq "${f}: every title names the org scope" \
        "$(jq -r '[.[].title | select(test("`mock-org`|in project `[^`]+`") | not)] | length' "${f}_issues.json")" "0"
    assert_eq "${f}: no contained resource name in any title" \
        "$(strip_scope < "${f}_issues.json" | jq -r '[.[] | select(test("payments-api|orders-api|catalog-api|backend-|prod|staging|mock-org"))] | length')" "0"
    assert_eq "${f}: no digits outside the scope" \
        "$(strip_scope < "${f}_issues.json" | jq -r '[.[] | select(test("[0-9]"))] | length')" "0"
done

# =============================================================================
# Wiring this tier cannot exercise behaviourally -- it runs the scripts directly,
# never `robot` -- so it is checked statically instead.
printf '\n%s== Scenario F -- generation rule and templates (static)%s\n' "${BLUE}" "${NC}"
cd "${HERE}" || exit 1
RB="${BUNDLE}/runbook.robot"
GR="${BUNDLE}/.runwhen/generation-rules/gcp-apigee-traffic-health.yaml"

# Comments are stripped FIRST throughout this section. The rule's and templates'
# own commentary quotes the very expressions being forbidden -- including the
# resource type, both qualifier forms, and match_resource.resource_name -- so
# matching the whole file passes even with the change reverted. That is an
# assertion which cannot fail, which is worse than no assertion at all.
GR_CODE="$(grep -v '^ *#' "${GR}")"
assert_has  "generation rule gates on the Apigee organization" \
    "${GR_CODE}" "gcp_apigee_organizations"
assert_has  "  ...anchored on the organization" \
    "${GR_CODE}" 'qualifiers: ["resource"]'
# ["project", "resource"] renders <project>-<project>-...-<hash>, because an
# Apigee X org is named after its GCP project.
assert_hasnt "  ...not doubled up with the project" \
    "${GR_CODE}" 'qualifiers: ["project", "resource"]'
# gcp-hierarchy.yaml inserts project_id into the path ONLY when `resource` is a
# qualifier, so ["project"] flattens resourcePath to gcp/<project>.
assert_hasnt "  ...not flattened back to the project" \
    "${GR_CODE}" 'qualifiers: ["project"]'

printf '  %sruns runbook-only%s\n' "${DIM}" "${NC}"
assert_hasnt "no SLI in outputItems"  "${GR_CODE}" "type: sli"
assert_hasnt "no SLO in outputItems"  "${GR_CODE}" "type: slo"
assert_eq "no sli.robot ships" \
    "$([ -e "${BUNDLE}/sli.robot" ] && echo present || echo absent)" "absent"
assert_eq "no SLI template ships" \
    "$(find "${BUNDLE}/.runwhen/templates" -name '*-sli.yaml' | wc -l | xargs)" "0"
assert_eq "no SLO template ships" \
    "$(find "${BUNDLE}/.runwhen/templates" -name '*-slo.yaml' | wc -l | xargs)" "0"
# Deleting the SLI must not take a check with it. Asserted on script names so the
# coverage claim is checked rather than trusted.
for s in check_error_rates check_latency check_throughput check_target_performance; do
    assert_has "${s}.sh, which the SLI scored, is still run by a runbook task" \
        "$(cat "${RB}")" "bash_file=${s}.sh"
done

for t in slx taskset; do
    TPLF="${BUNDLE}/.runwhen/templates/gcp-apigee-traffic-health-${t}.yaml"
    TPL="$(grep -v '^ *#' "${TPLF}")"
    # The bug this bundle shipped with: match_resource.resource_name is not an
    # attribute runwhen-local builds. CustomUndefined.__str__ returns a
    # placeholder rather than "", so APIGEE_ORG rendered as the literal string
    # `missing_workspaceInfo_custom_variable` and every Apigee call targeted a
    # non-existent org.
    assert_hasnt "${t}: never reads the non-existent match_resource.resource_name" \
        "${TPL}" "match_resource.resource_name"
    # APIGEE_ORG is the resolved org and nothing else. Checked on the value line
    # that follows the key, so setting it from {{project.name}} -- which is what
    # the sibling security bundle did, and which works by coincidence on Apigee X
    # only because the org ID happens to equal the project ID -- fails here.
    ORGVAL="$(grep -A1 'name: APIGEE_ORG' "${TPLF}" | grep 'value:')"
    # shellcheck disable=SC2016
    assert_has   "${t}: APIGEE_ORG is the resolved org" "${ORGVAL}" "value: '{{apigee_org}}'"
    assert_hasnt "${t}: APIGEE_ORG is not the project"  "${ORGVAL}" "project.name"
    # BOOLEAN mode is the whole point. Plain default() substitutes only for an
    # UNDEFINED value, so a workspaceInfo carrying `apigee_org: ""` renders
    # APIGEE_ORG empty and skips every fallback.
    # shellcheck disable=SC2016
    assert_has "${t}: org fallback is in boolean mode, not undefined-only" \
        "${TPL}" 'default(_res.name, true)'
    # The indexed payload must be materialised before its fields are read.
    # CustomUndefined subclasses plain Undefined, whose __getattr__ RAISES, so
    # reaching through match_resource.resource.name aborts the whole render with
    # UndefinedError when .resource is absent rather than falling through.
    # shellcheck disable=SC2016
    assert_has "${t}: indexed payload is materialised before use" \
        "${TPL}" 'match_resource.resource | default({}, true)'
    # shellcheck disable=SC2016
    assert_hasnt "${t}: never reaches through .resource.name in an expression" \
        "${TPL}" 'default(match_resource.resource.name'
    # gcp-tags.yaml renders the resource_name tag from qualifiers.resource, so
    # sharing that source is what stops the tag and APIGEE_ORG disagreeing.
    # shellcheck disable=SC2016
    assert_has "${t}: org falls back to the same source as the resource_name tag" \
        "${TPL}" 'default(qualifiers.resource, true)'
done

# The SLX is anchored on the org, so the scope tag says so -- lowercase, which is
# the collection's vocabulary for this tag.
SLX_TAGS="$(grep -A1 'name: scope' "${BUNDLE}/.runwhen/templates/gcp-apigee-traffic-health-slx.yaml")"
assert_has   "SLX scope tag is the organization" "${SLX_TAGS}" "value: organization"
assert_hasnt "  ...and not capitalised"          "${SLX_TAGS}" "value: Organization"

# =============================================================================
printf '\n%s== Scenario G -- runbook wiring (static)%s\n' "${BLUE}" "${NC}"
TASK_TITLES="$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\*/{f=0} f && /^[^ \t]/ && NF' "${RB}")"
# Task names are substituted from config_provided, NOT from Robot suite
# variables, so ${APIGEE_ORG} in a title only resolves because it is a
# config_provided key. Set Suite Variable would not work here.
# shellcheck disable=SC2016
assert_eq "every task title names the org" \
    "$(printf '%s\n' "${TASK_TITLES}" | grep -c 'in `${APIGEE_ORG}`')" "4"
assert_eq "no task title still names the project" \
    "$(printf '%s\n' "${TASK_TITLES}" | grep -c 'GCP_PROJECT_ID' || true)" "0"
assert_eq "four check tasks remain" \
    "$(printf '%s\n' "${TASK_TITLES}" | wc -l | xargs)" "4"
# Discovery can raise no finding about Apigee itself, only about its own ability
# to run. As a task it produced a dishonest task list: when it failed, every
# check still ran, found nothing and rendered as passed.
assert_eq "discovery is NOT a task" \
    "$(printf '%s\n' "${TASK_TITLES}" | grep -c '^Discover' || true)" "0"
assert_has "discovery failure fails the suite" \
    "$(cat "${RB}")" "Fail    Apigee metric scope discovery failed"
# The summary task raised no finding of its own -- it restated what the four
# checks had already reported, as a second issue against the same underlying
# fault.
assert_eq "the summary is not a task either" \
    "$(printf '%s\n' "${TASK_TITLES}" | grep -c '^Generate' || true)" "0"

printf '  %sauth: tolerant activation, strict token probe%s\n' "${DIM}" "${NC}"
# Gating on the activation exit code took a whole run down -- every task NOT RUN
# -- on a runner whose ambient identity was fine, because gcloud misread the key
# file as a .p12. Activation stays tolerant; the token probe does not, so a run
# with no identity at all still cannot report green.
#
# The single quotes below are load-bearing, not a style slip: these are Robot
# ${...} literals to match verbatim. Letting the shell expand them yields an
# empty needle, which every assert_has then "passes" against. SC2016 is exactly
# backwards here, so it is disabled per assertion rather than fixed.
# shellcheck disable=SC2016
assert_has "activation is tolerant" \
    "$(cat "${RB}")" 'activate-service-account --key-file="./${gcp_credentials.key}" || true'
# Match the gate itself, not the bare sentinel: TOKEN_ABSENT also appears in the
# probe's own `echo`, so asserting the word alone survives deleting the IF.
# shellcheck disable=SC2016
assert_has "the token probe is what gates the suite" \
    "$(cat "${RB}")" 'IF    "TOKEN_ABSENT" in """${token.stdout}"""'
assert_has "no obtainable token fails the suite" \
    "$(cat "${RB}")" "Fail    Could not obtain a GCP access token"
# shellcheck disable=SC2016
assert_hasnt "the suite does not gate on the activation returncode" \
    "$(cat "${RB}")" 'IF    ${auth.returncode} != 0'
# shellcheck disable=SC2016
assert_has "the auth failure issue reports the key shape" \
    "$(cat "${RB}")" 'key file shape: ${keyshape.stdout}'

# =============================================================================
# Every variable the README documents as operator configuration must actually be
# wired through, in ALL THREE places the platform needs it:
#
#   taskset configProvided   the SLX supplies the value
#   Import User Variable     the suite accepts it
#   the ${env} dict          the scripts can see it
#
# This is a CLASS assertion, not another instance. THROUGHPUT_DEVIATION_PCT was
# documented in the README and read by check_throughput.sh with a built-in
# default, but wired through none of the three -- so the built-in was the only
# reachable value and an operator following the README could not change it.
# Nothing was broken at the default, which is exactly why it survived: every
# behavioural assertion in this file passed while the promise was unkeepable.
#
# The behavioural scenarios cannot catch this, and adding more of them would not
# help: they export the variables themselves, so the scripts always see a value
# whether or not the runbook would ever supply one. They test each script's USE
# of a variable, never the platform's ability to SET it. Only a static check
# closes that gap.
#
# Scoped to the README's `## Configuration` section and to leading bullets, so
# prose mentions elsewhere -- KEY_JSON, TOKEN_ABSENT, and the thresholds named in
# the task descriptions -- are not mistaken for operator config. Genuinely
# internal variables (APIGEE_API, APIGEE_SCOPE_FILE) are not documented there and
# are correctly ignored.
printf '\n%s== Scenario H -- documented config is actually wired (static)%s\n' "${BLUE}" "${NC}"
TS="${BUNDLE}/.runwhen/templates/gcp-apigee-traffic-health-taskset.yaml"
# The backticks in the sed pattern are literal markdown, not a command
# substitution, so the single quotes are required. SC2016 is backwards here.
# shellcheck disable=SC2016
DOCUMENTED="$(awk '/^## Configuration/{f=1;next} /^## /{f=0} f' "${BUNDLE}/README.md" \
    | sed -n 's/^- `\([A-Z][A-Z0-9_]*\)`.*/\1/p' | sort -u)"
# Guard the extraction itself: a README refactor that renames the heading would
# silently yield an empty list, and every loop below would then vacuously pass.
assert_eq "the README's configuration list was found and is non-empty" \
    "$([ -n "${DOCUMENTED}" ] && echo yes || echo no)" "yes"
while IFS= read -r v; do
    [ -z "${v}" ] && continue
    assert_eq "${v}: supplied by the SLX (taskset configProvided)" \
        "$(grep -c "name: ${v}\$" "${TS}" | xargs)" "1"
    assert_eq "${v}: accepted by the suite (Import User Variable)" \
        "$(grep -c "Import User Variable    ${v}\$" "${RB}" | xargs)" "1"
    assert_eq "${v}: visible to the scripts (env dict)" \
        "$(grep -c "\"${v}\":" "${RB}" | xargs)" "1"
done <<< "${DOCUMENTED}"

# =============================================================================
# Every script runs `set -x`, and the access token is a live OAuth bearer
# credential valid for about an hour. Under xtrace it was written into the task's
# captured output on every run -- at the ASSIGNMENT, at the emptiness test, and
# at each request, so suppressing any one of those is not enough.
#
# The gcloud stub mints a known sentinel, so this asserts on the real trace of
# the real scripts rather than on the shape of the source.
printf '\n%s== Scenario I -- no access token reaches the xtrace stream%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
export PATH="${HERE}/bin:${PATH}"
export FIXTURES="${HERE}/fixtures/main"
export GCP_PROJECT_ID="mock-project" APIGEE_ORG="mock-org"
unset MOCK_DATA_FILE
bash "${BUNDLE}/discover_metrics_scope.sh" > tokentrace_discover.log 2>&1
assert_eq "discover_metrics_scope: token never appears in the trace" \
    "$(grep -c 'offline-fake-token' tokentrace_discover.log || true)" "0"
# Discovery above wrote apigee_scope.json, so the checks take their LIVE path --
# the only path that touches a token at all.
for s in ${CHECKS}; do
    bash "${BUNDLE}/${s}.sh" > "tokentrace_${s}.log" 2>&1
    assert_eq "${s}: token never appears in the trace" \
        "$(grep -c 'offline-fake-token' "tokentrace_${s}.log" || true)" "0"
done
# ...and the suppression must not have swallowed the failure path with it.
GCLOUD_NO_TOKEN=1 bash "${BUNDLE}/discover_metrics_scope.sh" > tokentrace_absent.log 2>&1
assert_eq "a missing token is still reported, not silently swallowed" \
    "$(issues discovery_issues.json)" "1"
assert_has "  ...and says it could not authenticate" \
    "$(titles discovery_issues.json)" "Cannot authenticate to Apigee in org"

# =============================================================================
# The key-shape probe is pure shell, so unlike the rest of the runbook it can be
# exercised for real. Extracted from runbook.robot rather than copied, so the
# thing under test is the string that actually ships -- a copy would drift and
# then assert about itself.
printf '\n%s== Scenario J -- key shape probe (behavioural)%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1

# shellcheck disable=SC2016
PROBE=$(grep -F 'echo KEY_MISSING' "${RB}" \
    | sed -e 's/^[[:space:]]*\.\.\.[[:space:]]*cmd=//' -e 's/\${gcp_credentials\.key}/testkey/')
probe() { eval "${PROBE}"; }

rm -f testkey
assert_eq "absent key file reports KEY_MISSING" "$(probe)" "KEY_MISSING"
: > testkey
assert_eq "empty key file reports KEY_EMPTY" "$(probe)" "KEY_EMPTY"

# The case that matters: gcloud reports a base64-encoded key with the same
# ".p12 keys" error as a missing one, which is what makes a live failure
# ambiguous. One error message, three different things to go fix.
printf 'eyJ0eXBlIjoic2VydmljZV9hY2NvdW50In0=' > testkey
assert_eq "base64-encoded key reports KEY_NOT_JSON" "$(probe)" "KEY_NOT_JSON"

printf '{"type":"service_account","project_id":"p"}' > testkey
assert_eq "well-formed key reports KEY_JSON" "$(probe)" "KEY_JSON"
printf '\n   {"type":"service_account","project_id":"p"}' > testkey
assert_eq "leading whitespace still reads as KEY_JSON" "$(probe)" "KEY_JSON"

# The probe's output lands in an issue, so it must carry the shape and none of
# the contents. Checked on BOTH branches: the not-JSON path is where a leak is
# likeliest, since that is where someone reaches for `cat` to explain what the
# file actually was.
for shape_case in '{"private_key":"LEAKCANARY"}' 'LEAKCANARY-not-json-at-all'; do
    printf '%s' "${shape_case}" > testkey
    assert_eq "probe emits a sentinel, never key bytes (${shape_case:0:12}...)" \
        "$(probe | grep -c 'LEAKCANARY' || true)" "0"
done
rm -f testkey

# =============================================================================
# The .test harness itself. None of this can be exercised behaviourally here --
# it provisions cloud resources and runs docker -- so it is checked statically.
# Every assertion below corresponds to a way the harness could report success
# while having done nothing.
printf '\n%s== Scenario K -- .test harness wiring (static)%s\n' "${BLUE}" "${NC}"
cd "${HERE}" || exit 1
TASKFILE="${BUNDLE}/.test/Taskfile.yaml"
# Comments stripped FIRST. The Taskfile now explains each of these hazards in
# prose, and several of those comments quote the very string being forbidden --
# `runwhen-local:latest` in the override hint, the old ajv idiom in the note
# about why it was wrong. Matching the whole file would fail on the
# documentation rather than on the code.
TF_CODE="$(grep -v "^[[:space:]]*#" "${TASKFILE}")"

# Fixture provisioning must exit non-zero when it cannot run. Printing
# "Skipping" and returning 0 told the caller the infrastructure existed when it
# did not, and every step after it then validated nothing.
assert_hasnt "build-infra no longer skips silently and reports success" \
    "${TF_CODE}" "Skipping Terraform apply"
assert_has "  ...it resolves credentials, which exit non-zero when absent" \
    "${TF_CODE}" ". ../load-credentials.sh"
assert_eq "the shared credential contract ships" \
    "$([ -f "${BUNDLE}/.test/load-credentials.sh" ] && echo yes || echo no)" "yes"

# The generation-rule guarantees moved out of the Taskfile into the shared
# validate_generation_rules.sh -- it had to grow an ajv-free path, because the
# codecollection-devtools image ships no node and `task ci` could not otherwise
# complete there. Assert against the script that now owns them.
# Comments stripped FIRST, same lesson as the generation rule and the Taskfile:
# this script's own header QUOTES "Skipping validation" as the thing it must not
# do, so matching the whole file fails on the documentation rather than on the
# code. That is the third time this trap has bitten in this family.
VGR_CODE="$(grep -v "^[[:space:]]*#" "${BUNDLE}/.test/validate_generation_rules.sh")"
# `ajv ... && echo valid || echo invalid` swallowed the failure: the block's exit
# status was the trailing `rm -rf`, so an invalid rule printed "is invalid" and
# the task still exited 0.
# The distinguishing feature of the broken form is the `&& echo ... || echo`
# chain, not the message: the fixed code still says "is invalid." inside a
# branch that also increments a failure counter.
# shellcheck disable=SC2016
assert_hasnt "generation-rule validation cannot swallow a failure" \
    "${VGR_CODE}" '|| echo "$yaml_file is invalid."'
assert_has "  ...it counts failures and exits non-zero" \
    "${VGR_CODE}" "generation rule(s) failed validation."
# An unchecked `curl -s` writes GitHub's error page into the schema on a 404, so
# every rule then fails against garbage while the task still exits 0.
assert_has "  ...the schema download is checked" "${VGR_CODE}" "curl -fsS -o"
assert_has "  ...and sanity-checked as JSON"     "${VGR_CODE}" "is not valid JSON"
# An unmatched glob expands to itself, so a renamed directory would validate
# nothing and report success.
assert_has "  ...and an empty rule set is an error" \
    "${VGR_CODE}" "no generation rules found under"

# On an image whose registry predates Apigee support, discovery exits 0 with
# ZERO SLXs, which reads as "the rule matched nothing" rather than as an image
# problem.
assert_hasnt "the discovery image is pinned, not :latest" \
    "${TF_CODE}" "runwhen-local:latest"
assert_has "  ...and the image is probed for the gated resource type first" \
    "${TF_CODE}" "does not know the resource type gcp_apigee_organizations"

# Without discovery in the chain, a green `task` run says nothing about the
# generation rule -- which is what most of this bundle's work was about.
#
# The full chain, and the rest of the standard vocabulary, is asserted in the
# shared block near the end of this file.
DEFAULT_CHAIN="$(awk '/^  default:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE}")"
assert_has "default reaches discovery" "${DEFAULT_CHAIN}" "run-rwl-discovery"

# Terraform here provisions nothing; it publishes what discovery should produce.
TF_MAIN="$(cat "${BUNDLE}/.test/terraform/main.tf" "${BUNDLE}/.test/terraform/outputs.tf")"
assert_hasnt "no inert placeholder bucket" "${TF_MAIN}" "google_storage_bucket"
assert_has "  ...ground truth is published instead" \
    "${TF_MAIN}" "discovery_expected_slx_count"


# --- Standard task vocabulary (static) ---------------------------------------
# Every gcp-apigee-* bundle declares the same task names with the same chains,
# so `task --list` reads identically in all five. Asserting on it here is what
# stops the five drifting apart again one convenience rename at a time.
TASKFILE_V="${BUNDLE}/.test/Taskfile.yaml"
TF_V="$(grep -v "^[[:space:]]*#" "${TASKFILE_V}")"
DEFAULT_CHAIN_V="$(awk '/^  default:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")"
CI_CHAIN_V="$(awk '/^  ci:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")"
CLEAN_CHAIN_V="$(awk '/^  clean:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")"

for t in ci test-offline test-render validate-generation-rules build-infra \
         test-live check-and-cleanup-fixtures check-unpushed-commits \
         generate-rwl-config run-rwl-discovery clean-rwl-discovery clean \
         bootstrap-prerequisites destroy-prerequisites preflight; do
    assert_has "task '${t}' is declared" "${TF_V}" "
  ${t}:"
done
# The old names. A leftover alias is one more thing an operator has to know,
# and `...-terraform` names the mechanism -- wrongly, for the bundles whose
# fixtures are REST objects Terraform never sees.
for t in run-mock-tests test-issue-generation check-and-cleanup-terraform; do
    assert_hasnt "the old name '${t}' is gone" "${TF_V}" "
  ${t}:"
done

assert_has "default runs the credential-free gate first" "${DEFAULT_CHAIN_V}" "task: ci"
assert_has "  ...then the live assertion tier"           "${DEFAULT_CHAIN_V}" "task: test-live"
assert_has "  ...and reaches discovery"                  "${DEFAULT_CHAIN_V}" "run-rwl-discovery"
assert_has "ci runs the offline tier"                    "${CI_CHAIN_V}" "task: test-offline"
assert_has "  ...the render tier"                        "${CI_CHAIN_V}" "task: test-render"
assert_has "  ...validates the generation rule"          "${CI_CHAIN_V}" "validate-generation-rules"
assert_has "  ...and checks the shared substrate"        "${CI_CHAIN_V}" "check-shared-drift"

# `task clean` must not require RunWhen Platform credentials. It used to call
# delete-slxs -> check-rwp-config, which exits 1 without RW_WORKSPACE/RW_API_URL/
# RW_PAT -- so clean-rwl-discovery never ran and a root-owned output/ was left
# behind after every local run on a machine with no Platform credentials.
assert_hasnt "clean does not require Platform credentials" "${CLEAN_CHAIN_V}" "delete-slxs"
assert_has "  ...and still removes the discovery output"  "${CLEAN_CHAIN_V}" "clean-rwl-discovery"

# The RunWhen Platform tasks come from the collection-wide Taskfile. The copies
# these bundles carried had all drifted to the v3 /branches/main/ endpoint.
assert_has "the shared RW taskfile is included" "${TF_V}" "../../.test-tasks/Taskfile.yaml"
assert_hasnt "  ...so no stale v3 branch endpoint is copied in here" \
    "${TF_V}" "branches/main/slxs"

# On an image whose registry predates Apigee support, discovery exits 0 with
# ZERO SLXs, which reads as "the rule matched nothing" rather than as an image
# problem.
assert_hasnt "the discovery image is pinned, not :latest" "${TF_V}" "runwhen-local:latest"
assert_has "  ...and probed for the gated resource type first" \
    "${TF_V}" "does not know the resource type gcp_apigee_organizations"

# The shared substrate must actually ship, or bootstrap-prerequisites is a
# task that names a file nobody added.
assert_eq "the shared prerequisites script ships" \
    "$([ -f "${BUNDLE}/.test/apigee_prerequisites.sh" ] && echo yes || echo no)" "yes"
assert_eq "the drift checker ships" \
    "$([ -f "${BUNDLE}/.test/check-shared-drift.sh" ] && echo yes || echo no)" "yes"
assert_eq "the live tier ships" \
    "$([ -f "${BUNDLE}/.test/test-live.sh" ] && echo yes || echo no)" "yes"

# The offline tier must be unable to REACH live credentials, not merely not use
# them. Without a gcloud stub first on PATH, the token fallback in the check
# scripts finds the REAL gcloud, so a "credential-free" run on any machine with
# ambient credentials mints a live ya29 token -- and then traces it. The stub
# directory is named bin in every bundle; it was mock in one and stubs in
# another, which is how one of them came to be missing the gcloud stub entirely.
assert_eq "the offline tier stubs gcloud" \
    "$([ -x "${BUNDLE}/.test/offline/bin/gcloud" ] && echo yes || echo no)" "yes"
assert_eq "  ...and curl" \
    "$([ -x "${BUNDLE}/.test/offline/bin/curl" ] && echo yes || echo no)" "yes"


# --- C9: the substrate contract (static) -------------------------------------
# Environments and the runtime instance are substrate, not any one bundle's
# fixtures: an EVALUATION org caps them at 2 and 1 respectively, and a capped
# resource is shared by definition. Four of the five bundles need the
# environments and none can create its own.
assert_has "build-infra bootstraps the substrate itself" \
    "$(awk '/^  build-infra:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")" "task: bootstrap-prerequisites"
assert_has "  ...and preflights it before creating anything" \
    "$(awk '/^  build-infra:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")" "task: preflight"
assert_eq "the shared preflight ships" \
    "$([ -f "${BUNDLE}/.test/apigee_preflight.sh" ] && echo yes || echo no)" "yes"

# The contract has to be written down where the next person looks, because the
# unattached environment WILL otherwise get "tidied up" -- and attaching it
# deletes environment-health's known-positive for check_instance_attachments,
# making that check pass because there is nothing to find.
PREREQ_V="$(cat "${BUNDLE}/.test/apigee_prerequisites.sh")"
assert_has "the substrate contract is stated in the shared script" \
    "${PREREQ_V}" "THE SUBSTRATE CONTRACT"
assert_has "  ...including the unattached-is-a-fixture invariant" \
    "${PREREQ_V}" "BEING UNATTACHED IS A FIXTURE, NOT A DEFECT"
assert_has "bootstrap creates both substrate environments" \
    "${PREREQ_V}" "_ensure_environment \"\${APIGEE_ENV_UNATTACHED}\""
assert_has "  ...and the runtime instance" "${PREREQ_V}" "_ensure_instance"
assert_has "  ...and attaches only the healthy one" \
    "${PREREQ_V}" "_ensure_attachment \"\${APIGEE_INSTANCE}\" \"\${APIGEE_ENV_HEALTHY}\""
# Concurrency: two bundles may bootstrap at once, and the loser must no-op.
assert_has "environment creation tolerates a concurrent creator" "${PREREQ_V}" "409)     note \"environment"

# The preflight must assert the contract BY NAME. A count cannot catch the
# failure that motivated it: with one environment instead of two, proxy-health's
# bootstrap skips its drift fixture behind `if [ -n "$env2" ]` and
# check_revision_drift.sh then reports clean because nothing was created to
# drift.
PREFLIGHT_V="$(cat "${BUNDLE}/.test/apigee_preflight.sh")"
assert_has "preflight asserts the environments by name" \
    "${PREFLIGHT_V}" "for want in \"\${APIGEE_ENV_HEALTHY}\" \"\${APIGEE_ENV_UNATTACHED}\""
assert_has "  ...reads /environments as the bare array the API returns" \
    "${PREFLIGHT_V}" 'if type=="array" then .[]'
assert_has "  ...requires a runtime instance" "${PREFLIGHT_V}" "has no runtime instance"
assert_has "  ...and that the healthy environment is attached" \
    "${PREFLIGHT_V}" "is not attached to runtime instance"
assert_has "  ...and warns if the unattached fixture was attached" \
    "${PREFLIGHT_V}" "IS attached to"


# --- the offline tier must be hermetic ---------------------------------------
# It reported different results on different machines until this landed: anyone
# who had sourced load-credentials.sh (which exports TF_VAR_org_id) carried a
# real org into a tier that is supposed to see only fixtures.
SELF_V="$(cat "${HERE}/run.sh")"   # not "$0": the cwd has moved by now
assert_has "the offline tier unsets the caller's credentials" \
    "${SELF_V}" "unset APIGEE_ORG GCP_PROJECT_ID"
assert_has "  ...including the TF_VAR_ spellings load-credentials.sh exports" \
    "${SELF_V}" "TF_VAR_org_id TF_VAR_project_id"


# --- generation-rule validation must not be hostage to one Node CLI ----------
# ajv is the collection convention (44 of 47 bundles), but codecollection-devtools
# ships no node, npm or ajv -- so `task ci`, the credential-free gate, could not
# complete in the container everyone tests in.
assert_eq "the shared rule validator ships" \
    "$([ -f "${BUNDLE}/.test/validate_generation_rules.sh" ] && echo yes || echo no)" "yes"
assert_has "it prefers ajv, the collection convention" "${VGR_CODE}" 'command -v ajv'
assert_has "  ...and falls back to Python jsonschema"  "${VGR_CODE}" "Draft202012Validator"
# The three non-ajv bundles in this collection print "Skipping validation" and
# exit 0. An absent check reports the same green as a passing one, which is the
# failure this family keeps designing against.
assert_hasnt "  ...and never skips when no validator is present" "${VGR_CODE}" "Skipping validation"
assert_has "  ...it fails, naming both install routes" "${VGR_CODE}" "no JSON Schema validator available"
assert_has "  ...npm route" "${VGR_CODE}" "npm install -g ajv-cli"
assert_has "  ...pip route" "${VGR_CODE}" "pip install jsonschema"


# test-live must resolve credentials itself. Three of the five scripts sourced
# nothing and only one task did, so `task test-live` died on an unset
# GCP_PROJECT_ID in exactly the bundles whose live tier had never been run --
# and the task bodies differed, which the vocabulary exists to prevent.
TL_CHAIN_V="$(awk '/^  test-live:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")"
assert_has "test-live sources the credential contract" "${TL_CHAIN_V}" ". ./load-credentials.sh"
assert_has "  ...and runs the live script"             "${TL_CHAIN_V}" "./test-live.sh"


# Neither discovery task may run an UNCONDITIONAL `sudo rm -rf output`. output/
# is root-owned only because a previous discovery container created it, so on a
# fresh checkout there is nothing to remove and sudo is pure cost -- and on a
# host without passwordless sudo it fails the task outright. run-rwl-discovery
# had exactly that and died on a developer laptop before pulling an image.
DISC_V="$(awk '/^  run-rwl-discovery:/{f=1;next} /^  [a-z-]+:/{f=0} f' "${TASKFILE_V}")"
# The old form is identified by its own error string, not by "sudo rm -rf
# output" -- the FIXED form contains that too, as the fallback arm.
assert_hasnt "run-rwl-discovery does not force sudo" "${DISC_V}" "Failed to remove output directory"
assert_has   "  ...it tries without sudo first"      "${DISC_V}" "rm -rf output 2>/dev/null || sudo rm -rf output"


# All five Apigee SLXs must use the SAME icon, and it must be one that exists.
# Two bundles pointed at icons/gcp/apigee/apigee.svg and
# icons/gcp/access-context-manager/access-context-manager.svg -- both 403, so the
# UI silently fell back to the generic default, and one of them named a different
# GCP service entirely. Only apigee_api_platform resolves.
SLX_TPL_V="$(cat "${BUNDLE}"/.runwhen/templates/*slx.yaml)"
assert_has "the SLX uses the shared Apigee icon" \
    "${SLX_TPL_V}" "icons/gcp/apigee_api_platform/apigee_api_platform.svg"
assert_hasnt "  ...not the non-existent apigee/apigee.svg" \
    "${SLX_TPL_V}" "icons/gcp/apigee/apigee.svg"
assert_hasnt "  ...nor an unrelated service's icon" \
    "${SLX_TPL_V}" "access-context-manager"

# =============================================================================
printf '\n%s== summary%s\n' "${BLUE}" "${NC}"
printf '  %s%d passed%s, %s%d failed%s\n' "${GREEN}" "${PASS}" "${NC}" \
    "$([ "${FAIL}" -gt 0 ] && echo "${RED}" || echo "${GREEN}")" "${FAIL}" "${NC}"
if [ "${FAIL}" -gt 0 ]; then
    printf '  logs: %s\n' "${WORK}"
    if [ "${VERBOSE}" = "-v" ]; then
        for f in "${WORK}"/*.log; do printf '\n--- %s\n' "$f"; cat "$f"; done
    fi
    exit 1
fi
rm -rf "${WORK}"
exit 0
