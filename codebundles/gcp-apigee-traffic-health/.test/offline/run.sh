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
# The key-shape probe is pure shell, so unlike the rest of the runbook it can be
# exercised for real. Extracted from runbook.robot rather than copied, so the
# thing under test is the string that actually ships -- a copy would drift and
# then assert about itself.
printf '\n%s== Scenario H -- key shape probe (behavioural)%s\n' "${BLUE}" "${NC}"
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
cd "${HERE}" || exit 1
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
