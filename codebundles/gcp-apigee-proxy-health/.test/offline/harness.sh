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

# The SLX is anchored on the Apigee ORGANIZATION -- the generation rule gates on
# gcp_apigee_organizations -- so a title naming the project labels an org-level
# finding as a project-level one. Three title shapes are legitimate:
#
#   ... in org `apigee-test-org`      a contained resource failed
#   ... in project `apigee-test-...`  discovery only: the org is precisely what
#                                     could not be determined, so the project is
#                                     the only identifier there is
#
# Stripping the scope is shared by the helpers below so the convention lives in
# one place; the org form is stripped only where it is backticked, so an
# unquoted mention still trips the resource-name guard.
# shellcheck disable=SC2016  # the $ anchors the sed address, not a variable
STRIP_SCOPE='s/ in org `[^`]*`$//; s/ in project `[^`]*`$//'

# assert_issue_title <label> <issues-file> <exact-condition-text>
# Asserts a title equals the condition exactly, ignoring the SLX scope suffix.
#
# Uses `grep -xF` -- a fixed-string, whole-line match -- rather than an anchored
# regex at each call site. That is strictly stronger (no metacharacter can widen
# it by accident), keeps the scope convention in one place, and avoids putting a
# regex `$` inside single quotes in a dozen places, which shellcheck rightly
# cannot distinguish from a mistyped variable.
assert_issue_title() {
    local label="$1" file="$2" condition="$3"
    local path="$WORKDIR/$file"
    if [ ! -f "$path" ]; then
        fail "$label" "a title equal to '$condition'" "$file was never written"
        return 0
    fi
    if jq -r '.[].title' "$path" 2>/dev/null \
       | sed "$STRIP_SCOPE" | grep -qxF "$condition"; then
        pass "$label"
    else
        fail "$label" "a title equal to '$condition' (scope suffix ignored)" \
             "no exact match" \
             "titles present: $(jq -r '[.[].title] | join(" | ")' "$path" 2>/dev/null)"
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

# assert_detail_matching <label> <issues-file> <regex>
# Aggregating by condition is only correct if the affected resources survive in
# the details. Asserting the title alone would pass a change that dropped them.
assert_detail_matching() {
    local label="$1" file="$2" regex="$3"
    local path="$WORKDIR/$file"
    if [ ! -f "$path" ]; then
        fail "$label" "details matching /$regex/" "$file was never written"
        return 0
    fi
    if jq -r '.[].details' "$path" 2>/dev/null | grep -qiE "$regex"; then
        pass "$label"
    else
        fail "$label" "details matching /$regex/" "no match" \
             "details: $(jq -r '[.[].details] | join(" ")' "$path" 2>/dev/null | head -c 200)"
    fi
}

# assert_titles_stable <label>
# Scans EVERY issue title produced by the scenario for things that change while
# the underlying condition does not: resource names from the fixtures, and bare
# numbers (counts, rates, revisions, latencies). A title carrying either mints a
# new issue whenever the estate shifts, orphaning the previous one.
#
# This is a blanket check rather than a per-title one on purpose -- a new check
# added later gets covered without anyone remembering to assert it.
assert_titles_stable() {
    local label="$1" titles offenders
    titles=$(cat "$WORKDIR"/*_issues.json 2>/dev/null | jq -r '.[]?.title' 2>/dev/null | sort -u)
    if [ -z "$titles" ]; then
        fail "$label" "at least one title to inspect" "no issues were produced"
        return 0
    fi
    # Resource identifiers from the fixtures, plus any bare integer. "401/403"
    # and "429" are HTTP status classes, not measurements, so they are exempt.
    # Strip the SLX scope suffix first. There is exactly one per SLX and it never
    # changes, so it belongs in the title -- but it would otherwise trip this
    # guard, which is looking for things that DO change between runs. The org is
    # the scope now, so it is stripped rather than banned outright; a mention
    # anywhere other than the trailing scope still counts as an offender.
    offenders=$(printf '%s\n' "$titles" \
        | sed "$STRIP_SCOPE" \
        | grep -vE '^Apigee proxies are rejecting requests with (401/403|429)$' \
        | grep -nE '\b(orders-api|payments-api|legacy-api|apigee-test-org|prod|test)\b|[0-9]+' || true)
    if [ -z "$offenders" ]; then
        pass "$label ($(printf '%s\n' "$titles" | grep -c .) distinct titles)"
    else
        fail "$label" "no resource ids or measurements in any title" \
             "$(printf '%s' "$offenders" | head -3 | tr '\n' ';')"
    fi
}

# assert_titles_scoped <label>
# Every title must end with the SLX scope, and the scope is the ORGANIZATION. The
# SLX is generated from gcp_apigee_organizations, so "... in project X" labels an
# org-level finding as a project-level one. There is exactly one org per SLX and
# it never changes, so naming it costs nothing in dedupe terms and tells an
# operator which SLX fired -- but nothing else asserts it, because
# assert_issue_title strips it.
#
# The ONE legitimate exception is an issue raised BECAUSE the org could not be
# determined; those are asserted separately and never appear in this scenario.
assert_titles_scoped() {
    local label="$1" titles unscoped
    titles=$(cat "$WORKDIR"/*_issues.json 2>/dev/null | jq -r '.[]?.title' 2>/dev/null | sort -u)
    if [ -z "$titles" ]; then
        fail "$label" "at least one title to inspect" "no issues were produced"
        return 0
    fi
    # shellcheck disable=SC2016  # the $ anchors the regex, not a variable
    unscoped=$(printf '%s\n' "$titles" | grep -vE 'in org `[^`]+`$' || true)
    if [ -z "$unscoped" ]; then
        pass "$label ($(printf '%s\n' "$titles" | grep -c .) titles)"
    else
        fail "$label" "every title ending in the org scope (in org \`...\`)" \
             "$(printf '%s' "$unscoped" | head -2 | tr '\n' ';')"
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

# assert_topology_status <label> <scenario> <ok|failed|absent>
#
# `status` is the field Suite Initialization branches on, and it has exactly two
# values now that the rule gates on the organization: `ok` (run the checks) and
# `failed` (do not). The former third value, "this project has no Apigee", was an
# artefact of the rule matching every indexed project and is gone with it.
#
# NOT `.status // "failed"`. jq's `//` falls through on `false` as well as null,
# so a helper that ever emitted a boolean here would read as the default and the
# assertion would pass under the exact mutation it exists to catch. `has()`
# separates "the field says X" from "the field is missing".
assert_topology_status() {
    local label="$1" scenario="$2" expected="$3"
    local path="$ARTIFACT_ROOT/$scenario/apigee_topology.json" actual
    if [ ! -f "$path" ]; then
        fail "$label" "status=$expected" "apigee_topology.json was never written"
        return 0
    fi
    actual=$(jq -r 'if has("status") then (.status | tostring) else "absent" end' \
             "$path" 2>/dev/null || echo "unparseable")
    if [ "$actual" = "$expected" ]; then
        pass "$label (status=$actual)"
    else
        fail "$label" "status=$expected" "status=$actual" \
             "reason: $(jq -r '.reason // "none"' "$path" 2>/dev/null)"
    fi
}

# assert_topology_org <label> <scenario> <expected-org>
# Failing the lookup while still recording another tenant's org would be one edit
# away from using it, so the recorded org is asserted too.
assert_topology_org() {
    local label="$1" scenario="$2" expected="$3" actual
    actual=$(jq -r '.organization // ""' \
             "$ARTIFACT_ROOT/$scenario/apigee_topology.json" 2>/dev/null || echo "UNREADABLE")
    if [ "$actual" = "$expected" ]; then
        pass "$label (organization='$actual')"
    else
        fail "$label" "organization='$expected'" "organization='$actual'"
    fi
}

# assert_topology_collections <label> <scenario>
# A failed topology must still carry real empty ARRAYS. `{}` or omitted keys
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

for scenario in healthy broken nocreds apierror absent-empty absent-apidisabled permdenied orgprefix statusunknown emptyorg undeployedonly decoyorg multiorg; do
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
# The SLX is project-scoped, so each condition is ONE issue naming the
# condition, with the affected resources in the details. Every block below
# therefore asserts three things: the exact count (aggregation happened), the
# title (stable, no resource identifiers), and the details (the resource is
# still named, so aggregation did not lose it).

# payments-api rev 5 is in ERROR state in prod with a non-empty errors[].
assert_issue_count     "[broken] deployment state: one aggregated issue"      deployment_state_issues.json eq 1
assert_issue_title  "[broken] ...titled by condition"                      deployment_state_issues.json "Apigee proxy deployments are in ERROR state"
assert_detail_matching "[broken] ...payments-api named in the details"        deployment_state_issues.json 'payments-api'

# orders-api: prod on rev 2, test on rev 3, latest is 3.
assert_issue_count     "[broken] revision drift: two aggregated issues"       revision_drift_issues.json eq 2
assert_issue_title  "[broken] ...one for stale revisions"                  revision_drift_issues.json "Apigee proxies are not running their latest revision"
assert_issue_title  "[broken] ...one for cross-environment drift"          revision_drift_issues.json "Apigee proxies have revision drift across environments"
assert_detail_matching "[broken] ...orders-api named in the details"          revision_drift_issues.json 'orders-api'

# One fault used to be reported by three tasks. Each now owns exactly one angle,
# so the de-duplication is asserted from BOTH sides: the owner still reports it,
# and the others stay silent. Asserting only the survivor would let a duplicate
# creep back unnoticed.
assert_issue_count     "[broken] undeployed proxies: one aggregated issue"    failed_deployments_issues.json eq 1
assert_issue_title  "[broken] ...titled by condition"                      failed_deployments_issues.json "Apigee proxies are not deployed to any environment"
assert_detail_matching "[broken] ...legacy-api named in the details"          failed_deployments_issues.json 'legacy-api'
assert_issue_absent    "[broken] ...and does NOT re-report the ERROR deploy"  failed_deployments_issues.json 'ERROR state'

# payments-api has 25 revisions, threshold is 20. The COUNT must not appear in
# the title -- it grows on every import while the condition holds.
assert_issue_count     "[broken] revision accumulation: one aggregated issue" revision_accumulation_issues.json eq 1
assert_issue_title  "[broken] ...titled without the revision count"        revision_accumulation_issues.json "Apigee proxies have accumulated excess revisions"
assert_detail_matching "[broken] ...payments-api and its count in the details" revision_accumulation_issues.json 'payments-api: 25 revisions'

# Two failed operations: one targets a deployment already reported as ERROR (so
# it must be skipped), one is an envgroup change nothing else can see (so it
# must be reported). This is what "narrowed, not weakened" has to mean.
assert_issue_count     "[broken] failed operations: one aggregated issue"     failed_operations_issues.json eq 1
assert_issue_title  "[broken] ...titled by condition"                      failed_operations_issues.json "Apigee management operations failed"
assert_detail_matching "[broken] ...naming the envgroup failure"              failed_operations_issues.json 'envgroup'
assert_stdout_matching "[broken] ...and says it skipped the duplicate"        check_failed_operations "already reported as an ERROR deployment"

# prod: orders-api policy_error 500/10000 = 0.05 > 0.01
#       payments-api target_error 620/8000 = 0.0775 > 0.01
# Kept as TWO issues on purpose: policy_error and target_error route to
# different owners, which is the whole point of splitting them.
assert_issue_count     "[broken] error split: two issues, by owner"           error_split_issues.json eq 2
assert_issue_title  "[broken] ...policy_error (proxy owner)"               error_split_issues.json "Apigee proxies have an elevated policy_error rate"
assert_issue_title  "[broken] ...target_error (backend owner)"             error_split_issues.json "Apigee proxies have an elevated target_error rate"
assert_detail_matching "[broken] ...orders-api named in the details"          error_split_issues.json 'orders-api'

# prod: orders-api p95 total 9000ms (>5000), overhead 8000ms (>500)
assert_issue_count     "[broken] latency split: two aggregated issues"        latency_split_issues.json eq 2
assert_issue_title  "[broken] ...latency, titled without the percentile"   latency_split_issues.json "Apigee proxies have high response latency"
assert_issue_title  "[broken] ...processing overhead"                      latency_split_issues.json "Apigee proxies have high Apigee processing overhead"
assert_detail_matching "[broken] ...p95 and orders-api in the details"        latency_split_issues.json 'p95.*orders-api|orders-api.*p95'

# prod: orders-api 401 = 1000/10000 = 0.10 > 0.02
#       payments-api 429 = 800/8000  = 0.10 > 0.05
# 401 and 403 share a threshold, so they are ONE finding; 429 has its own.
assert_issue_count     "[broken] http error rates: auth and rate-limit"       http_error_rate_issues.json eq 2
assert_issue_title  "[broken] ...401/403 as one auth finding"              http_error_rate_issues.json "Apigee proxies are rejecting requests with 401/403"
assert_issue_title  "[broken] ...429 separately"                           http_error_rate_issues.json "Apigee proxies are rejecting requests with 429"
assert_detail_matching "[broken] ...the offending proxies in the details"     http_error_rate_issues.json 'orders-api'

# The whole point: no title anywhere carries a resource identifier or a
# measured value. Both would churn as the estate changes.
assert_titles_stable "[broken] no title carries a resource id or measurement"
# ...and the converse. assert_issue_title deliberately ignores the scope suffix
# so it tolerates formatting drift, which means it would NOT notice the scope
# disappearing entirely. Assert its presence separately.
assert_titles_scoped "[broken] every title carries the SLX scope"

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

# GET /organizations returns every org the SERVICE ACCOUNT can see, not the orgs
# in this project -- there is no ?parent=projects/... filter. Picking the first
# entry positionally would produce a SUCCESSFUL run confidently describing
# another tenant's project.
#
# The credential these bundles share can see every org in the estate. Two cases
# have to hold, and the second is the one that actually happens day to day:
#
#   decoyorg  many orgs visible, NONE for this project -> adopt none, fail
#   multiorg  many orgs visible, one for this project  -> adopt exactly that one
#
# multiorg puts the right org THIRD of four and serves the BROKEN dataset from
# every other org, so selecting positionally produces a clean-looking run with
# the wrong estate's findings rather than an obviously broken one.
assert_topology_org "[multiorg] the org for THIS project is selected" multiorg "apigee-test-org"
assert_topology_status "[multiorg] ...and the inventory is usable" multiorg ok
WORKDIR="$ARTIFACT_ROOT/multiorg"
assert_stdout_matching "[multiorg] ...and discovery says so" discover_proxies "Using Apigee organization: apigee-test-org"
assert_issue_count "[multiorg] no findings leak in from another org" \
    revision_drift_issues.json eq 0
assert_issue_count "[multiorg] ...nor undeployed proxies from another org" \
    failed_deployments_issues.json eq 0

# The rule gates on gcp_apigee_organizations, so an SLX exists only where an org
# was indexed. Seeing other tenants' orgs and none for this project is therefore
# a failure to determine, NOT a determination that Apigee is unused -- the old
# not-applicable verdict was an artefact of matching every project and is gone
# with the gate. What has NOT changed is the part that matters: another tenant's
# org is never adopted.
assert_topology_status "[decoyorg] other tenants' orgs are not adopted" decoyorg failed
assert_topology_org "[decoyorg] and no org is recorded either" decoyorg ""
WORKDIR="$ARTIFACT_ROOT/decoyorg"
assert_issue_count "[decoyorg] the failure to determine is reported" \
    apigee_discovery_issues.json ge 1
assert_issue_matching "[decoyorg] ...saying the org could not be determined" \
    apigee_discovery_issues.json 'Cannot determine the Apigee organization'
assert_issue_count "[decoyorg] and no findings from the wrong org" \
    deployment_state_issues.json eq 0

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

# --- every way the org lookup can come up empty is a FAILURE ------------------
# The rule gates on gcp_apigee_organizations, so the SLX exists only where an org
# was indexed and APIGEE_ORG normally arrives from the SLX. These scenarios drive
# the direct-invocation lookup, where "no org" means the run is misconfigured or
# blind -- never that Apigee is unused. All three must reach the SAME verdict by
# three different routes, and none may pass silently.
echo
bold "--- an org that cannot be named is a failure, by every route ---"

# F. A successful list that contains no org mapped to this project.
assert_topology_status "[absent-empty] empty list is a failure to determine" absent-empty failed
assert_topology_collections "[absent-empty] failed topology uses real arrays" absent-empty
WORKDIR="$ARTIFACT_ROOT/absent-empty"
assert_issue_count "[absent-empty] raises an issue" apigee_discovery_issues.json ge 1
assert_issue_matching "[absent-empty] ...saying it could not determine" \
    apigee_discovery_issues.json 'Cannot determine the Apigee organization'

# G. The Apigee API never enabled on the project (403 SERVICE_DISABLED). Under
#    the old project-gated rule this was read as a determination of absence. It
#    is not one here: the org was indexed, so the API answering "disabled" means
#    this run cannot see what the indexer saw.
assert_topology_status "[absent-apidisabled] a disabled API is a failure too" absent-apidisabled failed
assert_topology_collections "[absent-apidisabled] failed topology uses real arrays" absent-apidisabled
WORKDIR="$ARTIFACT_ROOT/absent-apidisabled"
assert_issue_count "[absent-apidisabled] raises an issue" apigee_discovery_issues.json ge 1

# H. A plain permission denial. This says NOTHING about whether Apigee is used
#    here, and never did -- it was a failure before the gate changed and still is.
assert_topology_status "[permdenied] permission denial is a failure" permdenied failed
WORKDIR="$ARTIFACT_ROOT/permdenied"
assert_issue_count "[permdenied] still raises an issue" apigee_discovery_issues.json ge 1
assert_issue_matching "[permdenied] ...saying it could not determine" \
    apigee_discovery_issues.json 'Cannot determine the Apigee organization'

# The one deliberate exception to org-scoped titles: this issue fires BECAUSE the
# org could not be determined, so the project is the only identifier it has.
# shellcheck disable=SC2016  # backticks are the title's own quoting, not a subshell
assert_issue_matching "[permdenied] ...scoped to the project, the only id it has" \
    apigee_discovery_issues.json 'in project `apigee-test-project`'

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
# nothing, and with no SLI there is no score to misread -- but the inventory was
# established, which is what distinguishes this from a run that could not look.
# The runbook report carries the "nothing to judge" wording.
echo
bold "--- reachable orgs with nothing, or nothing deployed ---"
assert_topology_status "[emptyorg] the org was reached, so the inventory is ok" emptyorg ok
WORKDIR="$ARTIFACT_ROOT/emptyorg"
assert_issue_count "[emptyorg] discovery raises nothing" apigee_discovery_issues.json eq 0
assert_issue_count "[emptyorg] deployment state raises nothing" deployment_state_issues.json eq 0
assert_stdout_matching "[emptyorg] ...but the report says there was nothing to judge" \
    check_deployment_state "no deployment state to judge"

# An org whose proxies are deployed NOWHERE. This is a real finding, not an
# empty one: every proxy is orphaned, and the check must say so.
WORKDIR="$ARTIFACT_ROOT/undeployedonly"
assert_issue_count     "[undeployedonly] ONE issue, not one per proxy"       failed_deployments_issues.json eq 1
assert_detail_matching "[undeployedonly] ...with BOTH proxies in the details" failed_deployments_issues.json "shelf-api"
assert_detail_matching "[undeployedonly] ...including the second one"         failed_deployments_issues.json "draft-api"
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
# =============================================================================
# STATIC assertions: generation rule, templates, runbook wiring.
#
# This tier drives the bash scripts directly and never runs `robot`, nor the
# indexer, so everything below is checked by reading the shipped files.
#
# assert_contains / assert_lacks <label> <haystack> <needle>
# Fixed-string, so a needle full of ${...} and {{...}} cannot be misread as a
# pattern. The haystack is passed in rather than a filename because several
# call sites strip comments first -- see why at the first one.
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label" "the file to contain: $needle" "not found"
    fi
}
assert_lacks() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
        fail "$label" "the file NOT to contain: $needle" \
             "found: $(printf '%s\n' "$haystack" | grep -F -- "$needle" | head -1)"
    else
        pass "$label"
    fi
}

bold "--- STATIC: the generation rule gates on the Apigee organization ---"
# Comments are stripped FIRST. The rule's own commentary names both the resource
# type and both qualifier forms while explaining the choice, so matching the
# whole file passes even with the gate reverted -- an assertion that cannot fail.
GR_CODE="$(grep -v '^ *#' "$BUNDLE_DIR/.runwhen/generation-rules/gcp-apigee-proxy-health.yaml")"
assert_contains "[rule] gates on gcp_apigee_organizations" "$GR_CODE" "gcp_apigee_organizations"
# Bare `project` generated an SLX for every indexed project in the workspace,
# which is what forced the old "does this project have Apigee at all?" branch.
assert_lacks    "[rule] ...and no longer on bare project"  "$GR_CODE" "- project"
# Not gcp_apigee_api_proxies either: the indexer emits one resource per proxy,
# so gating there yields one SLX per proxy -- hundreds per org.
assert_lacks    "[rule] ...nor per-proxy, which would fan out to hundreds of SLXs" \
    "$GR_CODE" "gcp_apigee_api_proxies"
# runwhen-local's gcp-hierarchy.yaml inserts project_id into the path ONLY when
# `resource` is a qualifier, so reverting to ["project"] silently flattens
# resourcePath from gcp/<project>/<org> to gcp/<project> and never names the org.
assert_contains "[rule] anchored on the organization"      "$GR_CODE" 'qualifiers: ["resource"]'
assert_lacks    "[rule] ...not flattened back to the project" "$GR_CODE" 'qualifiers: ["project"]'

echo
bold "--- STATIC: both templates resolve the org the same, safe way ---"
for t in slx taskset; do
    # Comments stripped, same reason: the block explaining why NOT to reach
    # through match_resource.resource.name contains that very string.
    TPL="$(grep -v '^ *#' "$BUNDLE_DIR/.runwhen/templates/gcp-apigee-proxy-health-${t}.yaml")"
    assert_contains "[$t] supplies APIGEE_ORG from the matched org" \
        "$TPL" "match_resource.resource"
    assert_contains "[$t] APIGEE_ORG is the resolved org, not an inline expression" \
        "$TPL" "value: '{{apigee_org}}'"
    # BOOLEAN mode is the whole point. Plain default() substitutes only for an
    # UNDEFINED value, so a workspaceInfo carrying `apigee_org: ""` renders
    # APIGEE_ORG empty and skips every fallback -- which is how the sibling
    # bundle came out empty on a live workspace while its resource_name tag was
    # populated.
    assert_contains "[$t] org fallback is in boolean mode, not undefined-only" \
        "$TPL" 'default(_res.name, true)'
    # The indexed payload must be materialised before its fields are read.
    # runwhen-local's CustomUndefined subclasses plain Undefined, whose
    # __getattr__ RAISES, so reaching through match_resource.resource.name aborts
    # the whole render with UndefinedError when .resource is absent rather than
    # falling through. The render tier proves this behaviourally.
    assert_contains "[$t] indexed payload is materialised before use" \
        "$TPL" 'match_resource.resource | default({}, true)'
    assert_lacks "[$t] never reaches through .resource.name in an expression" \
        "$TPL" 'default(match_resource.resource.name'
    # gcp-tags.yaml renders the resource_name tag from qualifiers.resource, so
    # sharing that source is what stops the tag and APIGEE_ORG disagreeing.
    assert_contains "[$t] org falls back to the same source as the resource_name tag" \
        "$TPL" 'default(qualifiers.resource, true)'
done
# The SLX is anchored on the org, so its scope tag and alias must say so.
SLX_TPL="$(cat "$BUNDLE_DIR/.runwhen/templates/gcp-apigee-proxy-health-slx.yaml")"
assert_contains "[slx] scope tag is the organization, not the project" \
    "$SLX_TPL" "value: organization"
assert_lacks "[slx] ...and the old project scope is gone" "$SLX_TPL" "value: Project"
assert_contains "[slx] alias names the org" "$SLX_TPL" "for org {{apigee_org}}"

echo
# --- STATIC: robot task names ------------------------------------------------
# Only a precondition, not proof. Task names are registered from the robot file
# and substituted against the runbook's `config_provided`, so the only real proof
# is the platform's `resolved_tasks` after discovery re-runs, which nothing here
# can reach.
#
# What CAN be checked is that every name interpolates a key config_provided
# actually sets. APIGEE_ORG now arrives from the SLX -- the rule gates on the
# organization, so the matched resource IS it and its name is known at render
# time. That is what makes it safe in a task name; resolving it at run time was
# not, because a Robot suite variable exists only during execution, after the
# platform has already registered the name.
bold "--- STATIC: every task name is anchored on the org ---"
RB="$(cat "$BUNDLE_DIR/runbook.robot")"
_tasknames=$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\* Keywords \*\*\*/{f=0} f && /^[^ \t]/ && NF' \
             "$BUNDLE_DIR/runbook.robot")
_ntasks=$(printf '%s\n' "$_tasknames" | grep -c .)
# The single quotes below are load-bearing, not a style slip: these are Robot
# ${...} literals to match verbatim. Letting the shell expand them yields an
# empty needle, which every match then "passes" against. SC2016 is exactly
# backwards here, so it is disabled per site rather than "fixed".
# shellcheck disable=SC2016
_orgnamed=$(printf '%s\n' "$_tasknames" | grep -cF 'in `${APIGEE_ORG}`' || true)
if [ "$_ntasks" -gt 0 ] && [ "$_orgnamed" -eq "$_ntasks" ]; then
    pass "[static] every task name names the org ($_orgnamed/$_ntasks)"
else
    # shellcheck disable=SC2016
    fail "[static] every task name names the org" "$_ntasks of $_ntasks" \
         "$_orgnamed of $_ntasks" \
         "first offender: $(printf '%s\n' "$_tasknames" | grep -vF 'in `${APIGEE_ORG}`' | head -1)"
fi
# The [Tags] lines still carry ${GCP_PROJECT_ID} and should; this looks only at
# the names, which are the column-0 lines awk extracted above.
assert_lacks "[static] no task name still names the project" \
    "$_tasknames" 'GCP_PROJECT_ID'
# Both keys must exist in config_provided or the substitution silently yields the
# literal ${...} in the platform's task list.
TASKSET="$(cat "$BUNDLE_DIR/.runwhen/templates/"*taskset.yaml)"
assert_contains "[static] APIGEE_ORG is present in the taskset config_provided" \
    "$TASKSET" "name: APIGEE_ORG"
assert_contains "[static] GCP_PROJECT_ID is present in the taskset config_provided" \
    "$TASKSET" "name: GCP_PROJECT_ID"

echo
bold "--- STATIC: auth gates on the token, not on the activation ---"
# `robot --dryrun` parses the file but executes no keyword, so nothing here runs
# Suite Initialization. Activation stays TOLERANT on purpose: the runner may
# already carry a usable identity, and gating the suite on this call's exit code
# took the sibling bundle's whole live run down with every task NOT RUN, because
# gcloud misread the key file as a .p12. The token probe is the real gate -- it
# asserts the capability every downstream call depends on rather than the
# mechanism that usually supplies it, so a run with no identity at all still
# cannot report green.
#
# Single quotes again load-bearing: Robot ${...} literals, matched verbatim.
# shellcheck disable=SC2016
assert_contains "[auth] activation is tolerant" \
    "$RB" 'activate-service-account --key-file="./${gcp_credentials.key}" || true'
# Match the gate itself, not the bare sentinel: TOKEN_ABSENT also appears in the
# probe's own `echo`, so asserting the word alone survives deleting the IF.
# shellcheck disable=SC2016
assert_contains "[auth] the token probe is what gates the suite" \
    "$RB" 'IF    "TOKEN_ABSENT" in """${token.stdout}"""'
assert_contains "[auth] no obtainable token fails the suite" \
    "$RB" "Fail    Could not obtain a GCP access token"
# shellcheck disable=SC2016
assert_lacks "[auth] the suite does not gate on the activation returncode" \
    "$RB" '$activation.returncode != 0'
# shellcheck disable=SC2016
assert_contains "[auth] the failure issue reports the key shape" \
    "$RB" 'key file shape: ${keyshape.stdout}'

echo
bold "--- STATIC: discovery is setup, and its failure stops the run ---"
assert_contains "[runbook] discovery failure fails the suite" \
    "$RB" "Fail    Apigee discovery could not establish an inventory"
# ...and raises what discovery found BEFORE failing. `Fail` aborts setup, so an
# Add Issue placed after it never reaches the platform: the run would end with a
# suite error and no finding to triage.
_before=$(printf '%s\n' "$RB" | grep -n 'discovery_issue_list' | tail -1 | cut -d: -f1)
_failat=$(printf '%s\n' "$RB" | grep -n 'Fail    Apigee discovery could not establish' | head -1 | cut -d: -f1)
if [ -n "$_before" ] && [ -n "$_failat" ] && [ "$_before" -lt "$_failat" ]; then
    pass "[runbook] discovery's own issues are raised before the suite fails"
else
    fail "[runbook] discovery's own issues are raised before the suite fails" \
         "an Add Issue loop over apigee_discovery_issues.json above the Fail" \
         "loop at line ${_before:-none}, Fail at line ${_failat:-none}"
fi
_discovery_tasks=$(printf '%s\n' "$_tasknames" | grep -c '^Discover' || true)
if [ "$_discovery_tasks" -eq 0 ]; then
    pass "[runbook] discovery is NOT a task"
else
    fail "[runbook] discovery is NOT a task" "0 discovery tasks" "$_discovery_tasks"
fi
# Every check must treat a missing topology as an error. Suite Initialization
# guarantees one exists, so absence means something is genuinely wrong -- reading
# it as an empty estate would report "no issues found" for a check that never
# looked at anything.
_guarded=0; _checks=0
for s in "$BUNDLE_DIR"/check_*.sh "$BUNDLE_DIR"/analyze_*.sh; do
    _checks=$((_checks + 1))
    grep -qF 'APIGEE_TOPOLOGY_FILE is missing' "$s" && _guarded=$((_guarded + 1))
done
if [ "$_checks" -gt 0 ] && [ "$_guarded" -eq "$_checks" ]; then
    pass "[runbook] every check errors on a missing topology ($_guarded/$_checks)"
else
    fail "[runbook] every check errors on a missing topology" "$_checks of $_checks" \
         "$_guarded of $_checks"
fi

echo
bold "--- STATIC: discovery runs on an image that knows the Apigee types ---"
# The rule gates on gcp_apigee_organizations, which reached runwhen-local's GCP
# resource-type registry in 0.11.11. The `latest` tag still resolves to 0.11.10,
# whose registry does not carry it -- and on that image discovery exits 0 having
# generated ZERO SLXs, with the reason in a WARNING above the summary. `latest`
# is therefore not "the newest usable image" here; it is too old.
#
# Comments stripped first, same lesson as the generation rule: the block
# explaining the trap quotes `runwhen-local:latest` as the override example, so
# matching the whole file would pass with the pin reverted.
TF_CODE="$(grep -v '^[[:space:]]*#' "$TEST_DIR/Taskfile.yaml")"
assert_contains "[taskfile] the runwhen-local image is pinned, not latest" \
    "$TF_CODE" 'RWL_IMAGE:-ghcr.io/runwhen-contrib/runwhen-local:0.11.11'
assert_lacks "[taskfile] ...and discovery does not run latest" \
    "$TF_CODE" '-d ghcr.io/runwhen-contrib/runwhen-local:latest'
# Asking the image what it knows beats trusting its tag, and turns "0 SLXs"
# (which reads as a bundle problem) into an image problem stated up front.
assert_contains "[taskfile] the image is checked for the type before it is run" \
    "$TF_CODE" 'gcp_resource_type_registry.yaml'

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
    local label="$1" want_fail="$2" must="$3" mustnot="$4" strip="${5:-}" suffix="${6:-live}"
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
            FIXTURE_SUFFIX="$suffix" APIGEE_TOKEN="offline-token" \
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
    1 'zip is required|archiver returned non-zero' '^Deployed ' zip
assert_bootstrap "[bootstrap] broken/absent jq: hard failure, no false Deployed" \
    1 'jq is required|jq is required to build|missing or not working' '^Deployed ' jq

# The success path. Without this the tier only proves the script can FAIL --
# and the two bugs found by a live run (bundle dir built in the wrong place,
# and the zip binary being demanded) both live on the path to success.
assert_bootstrap "[bootstrap] full run succeeds and verifies ground truth" \
    0 'Fixtures created and verified' 'ERROR' ""

# activate-gcloud.sh: the point is that it fails when no token can be obtained,
# NOT when one particular file is absent. An earlier version demanded
# .test/gcp.json.secret and blocked runs that could authenticate perfectly well
# from tf.secret's GOOGLE_APPLICATION_CREDENTIALS or an existing gcloud login.
echo
bold "--- credential activation accepts any path that yields a token ---"
# assert_activate <label> <expected-rc> <seed-key:yes|no> [ENV=VAL ...]
#
# Runs the script in an ISOLATED directory holding nothing but a copy of it.
# The earlier version ran it from .test itself, so on any machine set up for
# live runs the developer's real gcp.json.secret satisfied the first branch and
# the "no credentials at all" case exited 0. That assertion therefore passed
# only on machines without credentials -- exactly where it proves least, and it
# went red the moment a key was placed for `run-rwl-discovery`.
# GOOGLE_APPLICATION_CREDENTIALS is unset for the same reason: an ambient export
# would satisfy the third branch just as silently.
assert_activate() {
    local label="$1" want_rc="$2" seed_key="$3"; shift 3
    local dir="$ARTIFACT_ROOT/activate"
    rm -rf "$dir"; mkdir -p "$dir/bin" "$dir/run"
    cp "$TEST_DIR/activate-gcloud.sh" "$dir/run/"
    [ "$seed_key" = "yes" ] && printf '{"type":"service_account"}' > "$dir/run/gcp.json.secret"
    printf '{"type":"service_account"}' > "$dir/gac.json"
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
    ( cd "$dir/run" && env -u GOOGLE_APPLICATION_CREDENTIALS \
        PATH="$dir/bin:$PATH" AG_ACTIVATED="$dir/.activated" "$@" \
        bash -c '. ./activate-gcloud.sh' ) > "$dir/out" 2>&1
    rc=$?
    if [ "$rc" -eq "$want_rc" ]; then pass "$label (exit $rc)"
    else fail "$label" "exit $want_rc" "exit $rc" "$(tail -n 2 "$dir/out" | tr '\n' ' ')"; fi
}
# All three accepted paths, and the one rejection. The first was previously
# untested precisely because it was always ambiently true.
assert_activate "[activate] a gcp.json.secret beside the script is accepted" 0 yes FAKE_ACTIVE=
assert_activate "[activate] already-logged-in gcloud is accepted"            0 no  FAKE_ACTIVE=1
assert_activate "[activate] GOOGLE_APPLICATION_CREDENTIALS is accepted"      0 no  FAKE_ACTIVE= \
    GOOGLE_APPLICATION_CREDENTIALS="$ARTIFACT_ROOT/activate/gac.json"
assert_activate "[activate] no credentials at all is a hard failure"         1 no  FAKE_ACTIVE=

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
