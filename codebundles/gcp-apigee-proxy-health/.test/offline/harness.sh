#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# harness.sh -- offline assertion tier for gcp-apigee-proxy-health.
#
# Runs every check script against fixture API responses with no credentials and
# no cloud access, and asserts the issues each check reports. Two scenarios:
#
#   healthy  (known-negative)  every check MUST report zero issues
#   broken   (known-positive)  every check MUST report its specific issue
#
# The known-positive half is the part that matters: a check with no
# known-positive assertion is untested no matter how often it has run clean.
#
# Fixture provenance: response shapes are derived from the Apigee Management API
# discovery document (https://apigee.googleapis.com/$discovery/rest?version=v1),
# NOT from what these scripts expect. Where the real API has a trap the fixtures
# reproduce it -- see fixtures/README.md.
#
# Exits non-zero if ANY assertion fails, if a check exits non-zero, or if a
# check calls an endpoint the API does not define. Runs every assertion before
# exiting so one run shows the whole blast radius.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$HERE/../.." && pwd)"
TEST_DIR="$(cd "$HERE/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$HERE/.artifacts}"

rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"

PASS=0
FAIL=0
FAILURES=()

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

fail() {
    local name="$1" expected="$2" actual="$3" detail="${4:-}"
    FAIL=$((FAIL + 1))
    FAILURES+=("$name")
    red "  FAIL  $name"
    printf '        expected: %s\n' "$expected"
    printf '        actual:   %s\n' "$actual"
    [ -n "$detail" ] && printf '        %s\n' "$detail"
    return 0
}

pass() {
    PASS=$((PASS + 1))
    green "  PASS  $1"
    return 0
}

# --- run one check script inside a scenario workdir --------------------------
# run_check <scenario> <script>
# Sets: RC (exit code), ISSUES_JSON (path), WORKDIR
run_check() {
    local scenario="$1" script="$2"
    WORKDIR="$ARTIFACT_ROOT/$scenario"
    mkdir -p "$WORKDIR"

    if [ ! -f "$WORKDIR/.seeded" ]; then
        cp "$BUNDLE_DIR"/*.sh "$WORKDIR"/
        touch "$WORKDIR/.seeded"
    fi

    (
        cd "$WORKDIR" || exit 99
        # SC2030: the export is deliberately scoped to this subshell so each
        # scenario gets a clean environment.
        # shellcheck disable=SC2030
        export PATH="$HERE/mock:$PATH"
        # orgprefix re-runs the healthy fixtures with the org name written the
        # other way round, so it needs no fixtures of its own.
        if [ "$scenario" = "orgprefix" ]; then
            export FIXTURE_DIR="$HERE/fixtures/healthy"
        else
            export FIXTURE_DIR="$HERE/fixtures/$scenario"
        fi
        export MOCK_UNROUTED_LOG="$WORKDIR/unrouted.log"
        export MOCK_REQUEST_LOG="$WORKDIR/requests.log"
        export GCP_PROJECT_ID="apigee-test-project"
        if [ "$scenario" = "nocreds" ]; then
            # No token and no gcloud: the "could not run" state.
            unset GCP_ACCESS_TOKEN
        else
            export GCP_ACCESS_TOKEN="fake-offline-token"
        fi
        if [ "$scenario" = "apierror" ]; then
            # A supplied org skips resolution, so a wholly inaccessible org
            # cannot be caught by the org-resolution guard.
            export APIGEE_ORG="some-org"
        elif [ "$scenario" = "orgprefix" ]; then
            # The API resource-name form. Sibling gcp-apigee-* bundles
            # configure the org this way; unstripped it builds
            # /organizations/organizations/x and 404s every call.
            export APIGEE_ORG="organizations/apigee-test-org"
        else
            unset APIGEE_ORG
        fi
        bash "./$script" > "$WORKDIR/${script%.sh}.stdout" 2> "$WORKDIR/${script%.sh}.stderr"
    )
    RC=$?
}

# assert_exit_zero <label> <script>
assert_exit_zero() {
    local label="$1" script="$2"
    if [ "$RC" -eq 0 ]; then
        pass "$label: exits 0"
    else
        fail "$label: exits 0" "exit code 0" "exit code $RC" \
             "stderr tail: $(tail -n 3 "$WORKDIR/${script%.sh}.stderr" 2>/dev/null | tr '\n' ' ')"
    fi
}

# assert_issue_count <label> <issues-file> <op> <expected>
#   op is 'eq' or 'ge'
assert_issue_count() {
    local label="$1" file="$2" op="$3" expected="$4"
    local path="$WORKDIR/$file" actual
    if [ ! -f "$path" ]; then
        fail "$label" "$op $expected issue(s) in $file" "$file was never written" \
             "a check that cannot run must not be indistinguishable from healthy"
        return 0
    fi
    actual=$(jq 'length' "$path" 2>/dev/null)
    if [ -z "$actual" ]; then
        fail "$label" "$op $expected issue(s) in $file" "$file is not a JSON array" \
             "contents: $(head -c 200 "$path")"
        return 0
    fi
    case "$op" in
        eq) [ "$actual" -eq "$expected" ] && { pass "$label ($actual)"; return 0; } ;;
        ge) [ "$actual" -ge "$expected" ] && { pass "$label ($actual)"; return 0; } ;;
    esac
    fail "$label" "$op $expected issue(s)" "$actual issue(s)" \
         "titles: $(jq -r '[.[].title] | join(" | ")' "$path" 2>/dev/null)"
}

# assert_issue_matching <label> <issues-file> <regex>
assert_issue_matching() {
    local label="$1" file="$2" regex="$3"
    local path="$WORKDIR/$file"
    if [ ! -f "$path" ]; then
        fail "$label" "an issue matching /$regex/" "$file was never written"
        return 0
    fi
    if jq -r '.[].title' "$path" 2>/dev/null | grep -qiE "$regex"; then
        pass "$label"
    else
        fail "$label" "an issue whose title matches /$regex/" \
             "no matching issue" \
             "titles present: $(jq -r '[.[].title] | join(\" | \")' "$path" 2>/dev/null)"
    fi
}

# assert_issue_severity <label> <issues-file> <expected-max-severity>
# Severity drives how an issue is surfaced and escalated, so it is worth
# asserting rather than assuming.
assert_issue_severity() {
    local label="$1" file="$2" expected="$3"
    local path="$WORKDIR/$file" actual
    if [ ! -f "$path" ]; then
        fail "$label" "every issue at severity $expected" "$file was never written"
        return 0
    fi
    actual=$(jq -r '[.[].severity] | unique | join(",")' "$path" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label" "every issue at severity $expected" "severities present: ${actual:-none}"
    fi
}

# assert_issue_absent <label> <issues-file> <regex>
# De-duplication is only real if the second reporter stays silent. Asserting the
# survivor is present does not prove the duplicate is gone.
assert_issue_absent() {
    local label="$1" file="$2" regex="$3"
    local path="$WORKDIR/$file"
    if [ ! -f "$path" ]; then
        fail "$label" "no issue matching /$regex/" "$file was never written"
        return 0
    fi
    if jq -r '.[].title' "$path" 2>/dev/null | grep -qiE "$regex"; then
        fail "$label" "NO issue matching /$regex/ (another task owns it)" \
             "found: $(jq -r '[.[].title] | join(" | ")' "$path" 2>/dev/null)"
    else
        pass "$label"
    fi
}

# assert_stdout_matching <label> <scenario-script> <regex>
# The runbook surfaces each script's stdout via `Add Pre To Report`, so wording
# that distinguishes "nothing to judge" from "nothing wrong" is part of the
# product now that there is no score to carry that distinction.
assert_stdout_matching() {
    local label="$1" script="$2" regex="$3"
    local path="$WORKDIR/${script}.stdout"
    if [ ! -f "$path" ]; then
        fail "$label" "stdout matching /$regex/" "${script}.stdout was never written"
        return 0
    fi
    if grep -qiE "$regex" "$path"; then
        pass "$label"
    else
        fail "$label" "stdout matching /$regex/" "no match in ${script}.stdout"
    fi
}

# INTERIM: assert_applicable <label> <scenario> <true|false|absent>
#
# NOT `.applicable // "false"`. jq's `//` falls through on `false` as well as
# null, so a wrongly-set false would read as the default and the assertion would
# pass under the exact mutation it exists to catch. `has()` separates "the field
# says false" from "the field is missing".
assert_applicable() {
    local label="$1" scenario="$2" expected="$3"
    local path="$ARTIFACT_ROOT/$scenario/apigee_topology.json" actual
    if [ ! -f "$path" ]; then
        fail "$label" "applicable=$expected" "apigee_topology.json was never written"
        return 0
    fi
    actual=$(jq -r 'if has("applicable") then (.applicable | tostring) else "absent" end' \
             "$path" 2>/dev/null || echo "unparseable")
    if [ "$actual" = "$expected" ]; then
        pass "$label (applicable=$actual)"
    else
        fail "$label" "applicable=$expected" "applicable=$actual" \
             "reason: $(jq -r '.reason // "none"' "$path" 2>/dev/null)"
    fi
}

# INTERIM: assert_topology_collections <label> <scenario>
# A not-applicable topology must carry real empty ARRAYS. `{}` or omitted keys
# leave downstream jq reading null, where `(.list)[]` aborts under `set -e`.
assert_topology_collections() {
    local label="$1" scenario="$2"
    local path="$ARTIFACT_ROOT/$scenario/apigee_topology.json" actual
    actual=$(jq -r '[(.environments|type), (.proxies|type), (.deployments|type)] | join(",")' \
             "$path" 2>/dev/null || echo "unreadable")
    if [ "$actual" = "array,array,array" ]; then
        pass "$label"
    else
        fail "$label" "environments/proxies/deployments all array" "$actual"
    fi
}

# assert_no_unrouted <label>
assert_no_unrouted() {
    local label="$1"
    local log="$WORKDIR/unrouted.log"
    if [ ! -s "$log" ]; then
        pass "$label: called only endpoints the API defines"
    else
        fail "$label: called only endpoints the API defines" \
             "no requests to undefined endpoints" \
             "$(sort -u "$log" | wc -l | tr -d ' ') undefined endpoint(s) called" \
             "first: $(sort -u "$log" | head -n 1)"
    fi
}

# --- fixture plumbing self-test ----------------------------------------------
# A mis-routed fixture makes every downstream assertion vacuous: the checks see
# an empty or wrong document, report nothing, and a known-negative-only suite
# reads that as healthy. Gate the routing before trusting any result.
# assert_route <scenario> <url> <jq-probe> <expected>
assert_route() {
    local scenario="$1" url="$2" probe="$3" expected="$4" actual
    actual=$(FIXTURE_DIR="$HERE/fixtures/$scenario" \
             bash "$HERE/mock/curl" -s -H "Authorization: Bearer x" "$url" \
             | jq -r "$probe" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        pass "route [$scenario] ${url#https://apigee.googleapis.com/v1}"
    else
        fail "route [$scenario] ${url#https://apigee.googleapis.com/v1}" \
             "$probe == $expected" "$probe == ${actual:-<parse error>}"
    fi
}

B="https://apigee.googleapis.com/v1/organizations"
O="$B/apigee-test-org"

bold "=== gcp-apigee-proxy-health :: offline assertion tier ==="
echo "bundle:    $BUNDLE_DIR"
echo "artifacts: $ARTIFACT_ROOT"
echo
bold "--- fixture routing self-test ---"
assert_route broken "$B"                                              '.organizations|length'          1
assert_route broken "$O/deployments"                                  '.deployments|length'            4
assert_route broken "$O/apis?includeRevisions=true"                   '.proxies|length'                3
assert_route broken "$O/apis?includeRevisions=true"                   '[.proxies[]|select(.name=="payments-api")][0].revision|length' 25
assert_route broken "$O/apis?includeRevisions=true"                   '[.proxies[]|select(.name=="payments-api")][0].latestRevisionId' 25
assert_route broken "$O/environments"                                 'length'                         2
assert_route broken "$O/environments/prod/apis/payments-api/revisions/5/deployments" '.state'           ERROR
assert_route broken "$O/environments/test/apis/orders-api/revisions/3/deployments"   '.state'           READY
assert_route broken "$O/environments/prod/stats/apiproxy?select=sum%28message_count%29&timeUnit=minute" \
                    '.environments[0].dimensions|length'              2
assert_route broken "$O/environments/prod/stats/apiproxy?select=p95%28total_response_time%29&timeUnit=minute" \
                    '.environments[0].dimensions[0].metrics[0].name'  'p95(total_response_time)'
assert_route broken "$O/environments/prod/stats/apiproxy,response_status_code?select=x" \
                    '.environments[0].dimensions|length'              5
assert_route broken "$O/operations"                                   '.operations|length'             3
echo

for scenario in healthy broken nocreds apierror absent-empty absent-apidisabled permdenied orgprefix statusunknown emptyorg undeployedonly; do
    bold "--- scenario: $scenario ---"

    # Discovery runs first, exactly as the runbook orders it; the check scripts
    # then read its cached deployments/proxies from the same working directory.
    run_check "$scenario" discover_proxies.sh
    assert_exit_zero "[$scenario] discover_proxies" discover_proxies.sh

    for s in check_deployment_state check_revision_drift check_failed_deployments \
             check_revision_accumulation check_failed_operations \
             analyze_error_split analyze_latency_split analyze_http_error_rates; do
        run_check "$scenario" "$s.sh"
        assert_exit_zero "[$scenario] $s" "$s.sh"
    done
done

# --- known-negative: healthy fixtures must produce zero issues ---------------
echo
bold "--- known-negative assertions (healthy fixtures -> zero issues) ---"
WORKDIR="$ARTIFACT_ROOT/healthy"
assert_issue_count "[healthy] discovery reports no issues"            apigee_discovery_issues.json      eq 0
assert_issue_count "[healthy] deployment state clean"                 deployment_state_issues.json      eq 0
assert_issue_count "[healthy] no revision drift"                      revision_drift_issues.json        eq 0
assert_issue_count "[healthy] no failed/undeployed proxies"           failed_deployments_issues.json    eq 0
assert_issue_count "[healthy] no revision accumulation"               revision_accumulation_issues.json eq 0
assert_issue_count "[healthy] no failed operations"                   failed_operations_issues.json     eq 0
assert_issue_count "[healthy] error rates under threshold"            error_split_issues.json           eq 0
assert_issue_count "[healthy] latency under threshold"                latency_split_issues.json         eq 0
assert_issue_count "[healthy] http error rates under threshold"       http_error_rate_issues.json       eq 0
assert_no_unrouted "[healthy] whole run"

# --- known-positive: broken fixtures must produce the specific issues --------
echo
bold "--- known-positive assertions (broken fixtures -> specific issues) ---"
WORKDIR="$ARTIFACT_ROOT/broken"
# payments-api rev 5 is in ERROR state in prod with a non-empty errors[].
assert_issue_count    "[broken] deployment state flags the ERROR deployment" deployment_state_issues.json ge 1
assert_issue_matching "[broken] ...and names payments-api"                   deployment_state_issues.json 'payments-api'

# orders-api: prod on rev 2, test on rev 3, latest is 3.
assert_issue_count    "[broken] revision drift flags stale + cross-env drift" revision_drift_issues.json ge 2
assert_issue_matching "[broken] ...flags orders-api not on latest"            revision_drift_issues.json 'orders-api.*not on latest'
assert_issue_matching "[broken] ...flags cross-environment drift"             revision_drift_issues.json 'drift across environments'

# One fault used to be reported by three tasks. Each now owns exactly one angle,
# so the de-duplication is asserted from BOTH sides: the owner still reports it,
# and the others stay silent. Asserting only the survivor would let a duplicate
# creep back unnoticed.
assert_issue_count    "[broken] undeployed proxies: exactly one finding"      failed_deployments_issues.json eq 1
assert_issue_matching "[broken] ...flags legacy-api as undeployed"            failed_deployments_issues.json 'legacy-api.*not deployed'
assert_issue_absent   "[broken] ...and does NOT re-report the ERROR deploy"   failed_deployments_issues.json 'failed deploy'

# payments-api has 25 revisions, threshold is 20.
assert_issue_count    "[broken] revision accumulation flags payments-api"     revision_accumulation_issues.json ge 1
assert_issue_matching "[broken] ...names payments-api"                        revision_accumulation_issues.json 'payments-api'

# Two failed operations: one targets a deployment already reported as ERROR (so
# it must be skipped), one is an envgroup change nothing else can see (so it
# must be reported). This is what "narrowed, not weakened" has to mean.
assert_issue_count    "[broken] failed operations: only the unique one"        failed_operations_issues.json eq 1
assert_issue_matching "[broken] ...reports the envgroup failure"              failed_operations_issues.json "Failed long-running operation"
assert_stdout_matching "[broken] ...and says it skipped the duplicate"        check_failed_operations "already reported as an ERROR deployment"

# prod: orders-api policy_error 500/10000 = 0.05 > 0.01
#       payments-api target_error 620/8000 = 0.0775 > 0.01
assert_issue_count    "[broken] error split flags policy and target errors"   error_split_issues.json ge 2
assert_issue_matching "[broken] ...flags orders-api policy_error"             error_split_issues.json 'policy_error.*orders-api'
assert_issue_matching "[broken] ...flags payments-api target_error"           error_split_issues.json 'target_error.*payments-api'

# prod: orders-api p95 total 9000ms (>5000), overhead 8000ms (>500)
assert_issue_count    "[broken] latency split flags p95 and overhead"         latency_split_issues.json ge 2
assert_issue_matching "[broken] ...flags high p95 latency"                    latency_split_issues.json 'high p95 latency.*orders-api'
assert_issue_matching "[broken] ...flags high processing overhead"            latency_split_issues.json 'overhead.*orders-api'

# prod: orders-api 401 = 1000/10000 = 0.10 > 0.02
#       payments-api 429 = 800/8000  = 0.10 > 0.05
assert_issue_count    "[broken] http error rates flags 401 and 429"           http_error_rate_issues.json ge 2
assert_issue_matching "[broken] ...flags the 401 rate"                        http_error_rate_issues.json '401'
assert_issue_matching "[broken] ...flags the 429 rate"                        http_error_rate_issues.json '429'

assert_no_unrouted "[broken] whole run"

# --- a run that could not run must not look clean ----------------------------
# The SLI was dropped, so there is no score to gate. The runbook surfaces
# `apigee_discovery_issues.json` directly, which makes that file the whole
# signal: if a blind run leaves it empty, the runbook reports nothing wrong
# about an org it could not see. These assertions are what stand in for the
# former scoring-layer checks.
echo
bold "--- blindness must surface as an issue (the runbook's only signal) ---"

# A completely clean run is the baseline: if these were ever non-empty the
# assertions below would pass for the wrong reason.
WORKDIR="$ARTIFACT_ROOT/healthy"
assert_issue_count "[healthy] discovery reports nothing" apigee_discovery_issues.json eq 0

WORKDIR="$ARTIFACT_ROOT/nocreds"
assert_issue_count "[nocreds] discovery reports the auth failure" \
    apigee_discovery_issues.json ge 1
assert_issue_matching "[nocreds] ...and says it cannot authenticate" \
    apigee_discovery_issues.json 'cannot authenticate'

# Valid token but every call denied: the failure mode a live run surfaced that
# the offline tier could not. Org resolution is skipped when APIGEE_ORG is set,
# so nothing guards it except checking the HTTP status of each response.
WORKDIR="$ARTIFACT_ROOT/apierror"
assert_issue_count "[apierror] discovery reports the API failure" \
    apigee_discovery_issues.json ge 1
assert_issue_matching "[apierror] ...and names it as an API call failure" \
    apigee_discovery_issues.json 'API calls failed'
# The analytics tasks make their own live calls, so they must report the
# failure too rather than returning an empty, reassuring result.
assert_issue_matching "[apierror] error split reports it could not query" \
    error_split_issues.json 'API calls failed'
assert_issue_matching "[apierror] latency split reports it could not query" \
    latency_split_issues.json 'API calls failed'
assert_issue_matching "[apierror] http error rates reports it could not query" \
    http_error_rate_issues.json 'API calls failed'

# --- INTERIM: applicability -------------------------------------------------
# The generation rule matches every project, so the bundle decides at runtime
# whether it has anything to say. The whole safety argument is that absence is
# concluded ONLY from a definite answer -- so the three cases below must be
# asserted together. Two of them prove the feature works; the third proves it
# has not eaten the failure path.
echo
bold "--- INTERIM: applicability (absence vs failure to determine) ---"

# F. Definite absence, via a successful list containing no org for this project.
assert_applicable "[absent-empty] determined not applicable" absent-empty false
assert_topology_collections "[absent-empty] empty topology uses real arrays" absent-empty
WORKDIR="$ARTIFACT_ROOT/absent-empty"
assert_issue_count "[absent-empty] raises NO issue" apigee_discovery_issues.json eq 0

# G. Definite absence, via the Apigee API never having been enabled. No API,
#    no organization -- that is an answer, not a failure.
assert_applicable "[absent-apidisabled] determined not applicable" absent-apidisabled false
assert_topology_collections "[absent-apidisabled] empty topology uses real arrays" absent-apidisabled
WORKDIR="$ARTIFACT_ROOT/absent-apidisabled"
assert_issue_count "[absent-apidisabled] raises NO issue" apigee_discovery_issues.json eq 0

# H. Failure to determine: a plain permission denial. This says NOTHING about
#    whether Apigee is used here. It must stay an issue, must NOT be marked
#    not-applicable, and must score 0. This is the assertion that stops the
#    absence branch from being widened into a blind pass.
assert_applicable "[permdenied] NOT marked not-applicable" permdenied true
WORKDIR="$ARTIFACT_ROOT/permdenied"
assert_issue_count "[permdenied] still raises an issue" apigee_discovery_issues.json ge 1
assert_issue_matching "[permdenied] ...saying it could not determine" \
    apigee_discovery_issues.json 'Cannot determine the Apigee organization'

# Same healthy org, named "organizations/<org>" instead of "<org>". One value,
# two spellings across the sibling bundles; an operator copying between them
# must not get a silently blind run.
WORKDIR="$ARTIFACT_ROOT/orgprefix"
assert_issue_count "[orgprefix] prefixed org name discovers the same org" \
    apigee_discovery_issues.json eq 0
assert_no_unrouted "[orgprefix] whole run"

# Proxies ARE deployed, but their runtime status cannot be read. Unknown must
# read as unknown: gating "is this deployed?" on state == "READY" would report
# every proxy in the org as undeployed the moment the status view goes away.
WORKDIR="$ARTIFACT_ROOT/statusunknown"
assert_issue_matching "[statusunknown] deployment state reports status unavailable" \
    deployment_state_issues.json .status unavailable.
assert_issue_count "[statusunknown] deployed proxies are NOT called undeployed" \
    failed_deployments_issues.json eq 0

# An org that is reachable but contains nothing. Every check legitimately finds
# nothing, and with no SLI there is no score to misread -- but the org IS
# applicable (it exists), which distinguishes this from a project with no
# Apigee at all. The runbook report carries the "nothing to judge" wording.
echo
bold "--- reachable orgs with nothing, or nothing deployed ---"
WORKDIR="$ARTIFACT_ROOT/emptyorg"
assert_applicable "[emptyorg] the org exists, so it IS applicable" emptyorg true
assert_issue_count "[emptyorg] discovery raises nothing" apigee_discovery_issues.json eq 0
assert_issue_count "[emptyorg] deployment state raises nothing" deployment_state_issues.json eq 0
assert_stdout_matching "[emptyorg] ...but the report says there was nothing to judge" \
    check_deployment_state "no deployment state to judge"

# An org whose proxies are deployed NOWHERE. This is a real finding, not an
# empty one: every proxy is orphaned, and the check must say so.
WORKDIR="$ARTIFACT_ROOT/undeployedonly"
assert_issue_count "[undeployedonly] flags both undeployed proxies" failed_deployments_issues.json eq 2
assert_stdout_matching "[undeployedonly] ...and drift reports nothing to judge" \
    check_revision_drift "no revision drift to judge"

# --- harness scripts: teardown verification ----------------------------------
# The teardown assertion is what stops a failed run from leaving fixtures that
# the next run silently adopts. It has to be exercised, not just written: the
# first hand-run of it reported "nothing left over" for an org it could not
# query at all.
echo
bold "--- teardown verification (.test/teardown_apigee_fixtures.sh) ---"

# assert_teardown <scenario> <expected-exit> <expected-output-regex>
assert_teardown() {
    local scenario="$1" want_rc="$2" regex="$3"
    local dir="$ARTIFACT_ROOT/$scenario" rc out
    mkdir -p "$dir"
    out="$dir/teardown.out"
    (
        cd "$TEST_DIR" || exit 99
        # SC2031: shellcheck sees run_check's subshell export of PATH and warns
        # the value may be stale. It is not -- each scenario runs in its own
        # subshell and this reads the harness's own PATH, prefixing the mock so
        # the script under test resolves `curl` to it.
        # shellcheck disable=SC2031
        env PATH="$HERE/mock:$PATH" \
            FIXTURE_DIR="$HERE/fixtures/$scenario" \
            MOCK_UNROUTED_LOG="$dir/unrouted.log" \
            APIGEE_ORG="organizations/shared-org" \
            GCP_PROJECT_ID="apigee-test-project" \
            FIXTURE_SUFFIX="pr748a" \
            APIGEE_TOKEN="offline-token" \
            bash ./teardown_apigee_fixtures.sh
    ) > "$out" 2>&1
    rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        fail "[$scenario] teardown exit code" "exit $want_rc" "exit $rc" \
             "output tail: $(tail -n 2 "$out" | tr '\n' ' ')"
        return 0
    fi
    if grep -qE "$regex" "$out"; then
        pass "[$scenario] teardown exits $rc and reports /$regex/"
    else
        fail "[$scenario] teardown output" "output matching /$regex/" \
             "no match" "output tail: $(tail -n 3 "$out" | tr '\n' ' ')"
    fi
}

# --- Robot syntax -----------------------------------------------------------
# The offline tier drives the bash scripts directly and never executes the
# .robot files, so their control flow was previously unverified. That is how a
# `RETURN` in a task body (valid only inside a user keyword) and a missing
# Collections import both survived review of the now-removed SLI: neither is
# visible to the shell linters, and both would have broken it at runtime.
echo
# --- SLX / taskset templates -------------------------------------------------
# These are Jinja over YAML, so nothing else in the tier parses them -- and a
# stray colon in a prose field silently turns the rest of the document into a
# nested mapping. Strip the Jinja and require what remains to be valid YAML.
# (Caught exactly that in asMeasuredBy: "...rather than a score: there is no
# SLI..." would have failed to render.)
echo
bold "--- .runwhen templates parse as YAML once Jinja is stripped ---"
for tpl in "$BUNDLE_DIR"/.runwhen/templates/*.yaml; do
    tname=$(basename "$tpl")
    if sed 's/{%[^%]*%}//g; s/{{[^}]*}}/PLACEHOLDER/g' "$tpl" | yq -o=json '.' >/dev/null 2>&1; then
        pass "[template] $tname parses"
    else
        fail "[template] $tname parses" "valid YAML after Jinja substitution" \
             "$(sed 's/{%[^%]*%}//g; s/{{[^}]*}}/PLACEHOLDER/g' "$tpl" | yq -o=json '.' 2>&1 | head -1)"
    fi
done

echo
bold "--- robot dry-run (syntax + keyword resolution) ---"
if command -v robot >/dev/null 2>&1; then
    # shellcheck disable=SC2043  # one file today; the loop keeps adding another trivial
    for rf in runbook.robot; do
        out="$ARTIFACT_ROOT/${rf%.robot}.dryrun"
        if ( cd "$BUNDLE_DIR" && robot --dryrun --output NONE --log NONE --report NONE "$rf" ) > "$out" 2>&1; then
            pass "[robot] $rf dry-runs clean"
        else
            fail "[robot] $rf dry-runs clean" "0 failed tasks" \
                 "$(grep -oE '[0-9]+ tasks?, [0-9]+ passed, [0-9]+ failed' "$out" | tail -1)" \
                 "first error: $(grep -oE "^[0-9]+\) .*" "$out" | head -1)"
        fi
    done
else
    # Not silently skipped: an unrun check must not read as a passed one.
    fail "[robot] dry-run" "robot available to validate the .robot files" \
         "robot is not installed in this image" \
         "install robotframework, or run the tier in codecollection-devtools"
fi

# --- harness scripts: fixture provisioning -----------------------------------
# A live run found bootstrap_apigee_fixtures.sh continuing after `zip` failed,
# printing "Deployed <proxy> rev  to <env>" -- note the empty revision -- for
# three fixtures that were never created. Nothing was in the org afterwards.
# The offline tier had no coverage of the provisioning script at all, which is
# why the bug reached a live run.
echo
bold "--- fixture provisioning must fail hard, not narrate success ---"

# assert_bootstrap <label> <expect-rc-nonzero> <must-match> <must-NOT-match> [strip-tool]
assert_bootstrap() {
    local label="$1" want_fail="$2" must="$3" mustnot="$4" strip="${5:-}"
    local dir="$ARTIFACT_ROOT/bootstrap-${strip:-full}" out rc
    mkdir -p "$dir"; out="$dir/bootstrap.out"
    (
        cd "$TEST_DIR" || exit 99
        # A shim dir that shadows the named tool with a failing stub, so the
        # script meets a missing tool the way a real image would present it.
        shim="$dir/shim"; mkdir -p "$shim"
        if [ -n "$strip" ]; then
            # SC2016: single quotes are deliberate -- this is the stub script's own
    # source text, expanded when the stub runs, not here.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nexit 127\n' > "$shim/$strip"; chmod +x "$shim/$strip"
        fi
        # shellcheck disable=SC2031
        env PATH="$shim:$HERE/mock:$PATH" \
            FIXTURE_DIR="$HERE/fixtures/bootstrap" \
            MOCK_UNROUTED_LOG="$dir/unrouted.log" \
            APIGEE_ORG="apigee-test-org" GCP_PROJECT_ID="apigee-test-project" \
            FIXTURE_SUFFIX="offline" APIGEE_TOKEN="offline-token" \
            TMP_ROOT="$dir/tmp" \
            bash ./bootstrap_apigee_fixtures.sh
    ) > "$out" 2>&1
    rc=$?

    if [ "$want_fail" = "1" ] && [ "$rc" -eq 0 ]; then
        fail "$label" "non-zero exit" "exit 0" "output tail: $(tail -n 2 "$out" | tr '\n' ' ')"
        return 0
    fi
    if [ -n "$must" ] && ! grep -qiE "$must" "$out"; then
        fail "$label" "output matching /$must/" "no match" "tail: $(tail -n 2 "$out" | tr '\n' ' ')"
        return 0
    fi
    # Case-SENSITIVE and anchored: the false-success line is "Deployed <name>
    # rev <n> to <env>". A case-insensitive match also hits the fixture banner
    # "(deployed READY on latest...)", which is intent, not a claim.
    if [ -n "$mustnot" ] && grep -qE "$mustnot" "$out"; then
        fail "$label" "output NOT matching /$mustnot/" \
             "matched: $(grep -iE "$mustnot" "$out" | head -1)"
        return 0
    fi
    pass "$label (exit $rc)"
}

# Two environments reach this differently and both are correct: the devtools
# image has no zip at all, so the up-front tool check fires; a host that HAS zip
# meets the failing shim inside build_bundle instead. The invariant is the same
# either way -- stop, say why, and never print a "Deployed" line, because that
# line is what told a caller the fixtures existed.
assert_bootstrap "[bootstrap] broken/absent zip: hard failure, no false Deployed" \
    1 'zip is required|zip returned non-zero' '^Deployed ' zip
assert_bootstrap "[bootstrap] broken/absent jq: hard failure, no false Deployed" \
    1 'jq is required|ERROR' '^Deployed ' jq

# activate-gcloud.sh: the point is that it fails when no token can be obtained,
# NOT when one particular file is absent. An earlier version demanded
# .test/gcp.json.secret and blocked runs that could authenticate perfectly well
# from tf.secret's GOOGLE_APPLICATION_CREDENTIALS or an existing gcloud login.
echo
bold "--- credential activation accepts any path that yields a token ---"
assert_activate() {
    local label="$1" want_rc="$2"; shift 2
    local dir="$ARTIFACT_ROOT/activate"; mkdir -p "$dir/bin"
    # SC2016: the single quotes are deliberate. This is the stub script's own
    # source text -- $* and $AG_ACTIVATED must expand when the stub runs, not
    # when the heredoc is written.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\ncase "$*" in\n  "auth print-access-token") { [ -f "$AG_ACTIVATED" ] || [ -n "$FAKE_ACTIVE" ]; } && echo tok || exit 1 ;;\n  "auth activate-service-account --key-file="*) touch "$AG_ACTIVATED" ;;\n  "config get-value account") echo a.c ;;\nesac\n' > "$dir/bin/gcloud"
    chmod +x "$dir/bin/gcloud"
    rm -f "$dir/.activated"
    local rc
    # SC2031: reads the harness's own PATH, prefixing the stub dir. Not stale.
    # shellcheck disable=SC2031
    ( cd "$TEST_DIR" && env PATH="$dir/bin:$PATH" AG_ACTIVATED="$dir/.activated" "$@" \
        bash -c '. ./activate-gcloud.sh' ) > "$dir/out" 2>&1
    rc=$?
    if [ "$rc" -eq "$want_rc" ]; then pass "$label (exit $rc)"
    else fail "$label" "exit $want_rc" "exit $rc" "$(tail -n 2 "$dir/out" | tr '\n' ' ')"; fi
}
assert_activate "[activate] already-logged-in gcloud is accepted"  0 FAKE_ACTIVE=1
assert_activate "[activate] no credentials at all is a hard failure" 1 FAKE_ACTIVE=

assert_teardown teardown-clean       0 'no API proxies with suffix pr748a remain'
assert_teardown teardown-leftover    1 'API proxies still present'
# The one that matters most: an org that cannot be queried must not pass.
assert_teardown teardown-unreachable 1 'could not list API proxies to verify teardown'

# =============================================================================
echo
bold "=== summary ==="
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo
    red "failed assertions:"
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    echo
    echo "artifacts (stdout, stderr, issue JSON, request logs) preserved under:"
    echo "  $ARTIFACT_ROOT"
    exit 1
fi
green "all assertions passed"
echo "artifacts: $ARTIFACT_ROOT"
