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
        export PATH="$HERE/mock:$PATH"
        export FIXTURE_DIR="$HERE/fixtures/$scenario"
        export MOCK_UNROUTED_LOG="$WORKDIR/unrouted.log"
        export MOCK_REQUEST_LOG="$WORKDIR/requests.log"
        export GCP_PROJECT_ID="apigee-test-project"
        if [ "$scenario" = "nocreds" ]; then
            # No token and no gcloud: the "could not run" state.
            unset GCP_ACCESS_TOKEN
        else
            export GCP_ACCESS_TOKEN="fake-offline-token"
        fi
        unset APIGEE_ORG
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

# assert_sli_score <scenario> <expected-aggregate> <expected-subscore-each>
#
# Mirrors the arithmetic in sli.robot against the files a real run leaves
# behind. This is the only assertion that reaches the scoring layer, and it is
# the one that catches a bundle which cannot run reporting perfect health:
# script-level assertions all pass in that state, because every check correctly
# writes an empty result and exits 0.
assert_sli_score() {
    local scenario="$1" want_agg="$2" want_sub="$3"
    local dir="$ARTIFACT_ROOT/$scenario"
    local disc_count discovery_ok agg sub
    local counts=() names=(deployment_state revision_drift failed_deployments)
    local files=(deployment_state_issues.json revision_drift_issues.json failed_deployments_issues.json)

    # jq length ... || echo 1  -- a missing discovery file means it never ran.
    disc_count=$(jq length "$dir/apigee_discovery_issues.json" 2>/dev/null || echo 1)
    discovery_ok=$([ "$disc_count" -eq 0 ] && echo 1 || echo 0)

    local total=0 i=0
    for f in "${files[@]}"; do
        # jq length ... || echo -1  -- a missing file is not zero issues.
        local n sc
        n=$(jq length "$dir/$f" 2>/dev/null || echo -1)
        if [ "$discovery_ok" -eq 1 ] && [ "$n" -eq 0 ]; then sc=1; else sc=0; fi
        counts+=("${names[$i]}=$sc")
        total=$((total + sc))
        i=$((i + 1))
    done

    if [ "$discovery_ok" -eq 0 ]; then agg="0.00"; else agg=$(awk -v t="$total" 'BEGIN{printf "%.2f", t/3}'); fi

    local ok=1
    [ "$agg" != "$want_agg" ] && ok=0
    for c in "${counts[@]}"; do
        [ "${c#*=}" != "$want_sub" ] && ok=0
    done

    if [ "$ok" -eq 1 ]; then
        pass "[$scenario] SLI aggregate $agg with every sub-score $want_sub"
    else
        fail "[$scenario] SLI score" \
             "aggregate $want_agg, every sub-score $want_sub" \
             "aggregate $agg, sub-scores: ${counts[*]}" \
             "discovery_ok=$discovery_ok (discovery reported $disc_count issue(s))"
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
assert_route broken "$O/operations"                                   '.operations|length'             2
echo

for scenario in healthy broken nocreds; do
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

# payments-api rev 5 failed to deploy; legacy-api is deployed nowhere.
assert_issue_count    "[broken] failed deployments flags both cases"          failed_deployments_issues.json ge 2
assert_issue_matching "[broken] ...flags the failed payments-api deploy"      failed_deployments_issues.json 'failed deploy.*payments-api'
assert_issue_matching "[broken] ...flags legacy-api as undeployed"            failed_deployments_issues.json 'legacy-api.*not deployed'

# payments-api has 25 revisions, threshold is 20.
assert_issue_count    "[broken] revision accumulation flags payments-api"     revision_accumulation_issues.json ge 1
assert_issue_matching "[broken] ...names payments-api"                        revision_accumulation_issues.json 'payments-api'

# One long-running operation is done with an error.
assert_issue_count    "[broken] failed operations flags the errored op"       failed_operations_issues.json ge 1

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

# --- scoring layer: a run that cannot run must not score healthy -------------
echo
bold "--- SLI scoring assertions ---"
# Healthy org: discovery clean, no findings -> perfect score.
assert_sli_score healthy 1.00 1
# Faults present: every scored dimension has findings -> zero.
assert_sli_score broken  0.00 0
# No credentials at all: discovery reports the auth failure, which must force
# the aggregate AND every sub-metric to 0. Gating only the aggregate would
# still leave anyone alerting on a sub-metric looking at green.
assert_sli_score nocreds 0.00 0
WORKDIR="$ARTIFACT_ROOT/nocreds"
assert_issue_count "[nocreds] discovery reports the auth failure" \
    apigee_discovery_issues.json ge 1
assert_issue_matching "[nocreds] ...and says it cannot authenticate" \
    apigee_discovery_issues.json 'cannot authenticate'

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
