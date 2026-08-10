#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Offline known-positive tests for the gcp-apigateway-health checks.
#
# WHY THIS EXISTS
# ---------------
# `--dryrun` only resolves keywords; it never executes a check. And a live run
# against real GCP proves nothing on its own, because a check that crashes (or
# that silently accumulates its findings into a subshell) writes an empty issues
# file and reads as "healthy". Every defect found in PR #744 review was invisible
# to both.
#
# So: run each check against a stub gcloud that returns REAL-SHAPED payloads for
# a deliberately broken project, and assert each check REPORTS the thing it is
# supposed to catch. A check that finds nothing here is broken, not healthy.
#
# Also runs the same checks against a healthy project and asserts they report
# nothing -- catching the opposite failure (a check that always fires).
#
# Usage:  ./.test/offline/run_offline_checks.sh
# Requires: bash, jq, yq. Talks to no network and no GCP project.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'

# assert_count <label> <issues-file> <op> <expected>
assert_count() {
    local label="$1" file="$2" op="$3" want="$4" got
    if [ ! -f "$file" ]; then
        printf '%s FAIL%s %s -- %s was never written (the check crashed)\n' "$RED" "$OFF" "$label" "$file"
        fail=$((fail+1)); return
    fi
    if ! jq -e 'type == "array"' "$file" >/dev/null 2>&1; then
        printf '%s FAIL%s %s -- %s is not a JSON array: %s\n' "$RED" "$OFF" "$label" "$file" "$(head -c 120 "$file")"
        fail=$((fail+1)); return
    fi
    got=$(jq 'length' "$file")
    if [ "$op" = "ge" ] && [ "$got" -ge "$want" ]; then
        printf '%s PASS%s %s %s(%s issue(s))%s\n' "$GREEN" "$OFF" "$label" "$DIM" "$got" "$OFF"; pass=$((pass+1)); return
    fi
    if [ "$op" = "eq" ] && [ "$got" -eq "$want" ]; then
        printf '%s PASS%s %s %s(%s issue(s))%s\n' "$GREEN" "$OFF" "$label" "$DIM" "$got" "$OFF"; pass=$((pass+1)); return
    fi
    printf '%s FAIL%s %s -- expected %s %s, got %s\n' "$RED" "$OFF" "$label" "$op" "$want" "$got"
    fail=$((fail+1))
}

run_scenario() {
    local scen="$1"; shift
    local work; work=$(mktemp -d)
    cp "$BUNDLE"/*.sh "$work"/
    cd "$work" || exit 1

    export PATH="$HERE/stub-path-$scen:$PATH"
    mkdir -p "$HERE/stub-path-$scen"
    ln -sf "$HERE/stub-gcloud" "$HERE/stub-path-$scen/gcloud"
    # The metric and operations checks bypass gcloud and hit the Cloud
    # Monitoring / API Gateway REST APIs directly, so curl is stubbed too.
    ln -sf "$HERE/stub-curl" "$HERE/stub-path-$scen/curl"
    export GCP_PROJECT_ID="stub-project"
    export STUB_SCENARIO="$scen"
    export GCP_REGIONS="us-central1"

    ./discover_apigateway.sh   >/dev/null 2>&1
    ./check_states.sh          >/dev/null 2>&1
    ./check_invoker_binding.sh >/dev/null 2>&1
    ./check_config_drift.sh    >/dev/null 2>&1
    ./check_managed_service.sh >/dev/null 2>&1
    ./check_backends.sh        >/dev/null 2>&1
    ./check_error_rates.sh     >/dev/null 2>&1
    ./check_latency.sh         >/dev/null 2>&1
    ./check_operations.sh      >/dev/null 2>&1
    ./generate_summary.sh      >/dev/null 2>&1

    echo "$work"
}

echo "=============================================================="
echo " Scenario: BROKEN project -- every check must REPORT its defect"
echo "=============================================================="
W=$(run_scenario broken)

# Discovery must resolve the fields the real API actually provides.
loc=$(jq -r '.gateways[0].location' "$W/apigateway_inventory.json" 2>/dev/null)
if [ "$loc" = "us-central1" ]; then
    printf '%s PASS%s discovery: gateway location parsed from .name\n' "$GREEN" "$OFF"; pass=$((pass+1))
else
    printf '%s FAIL%s discovery: gateway location = %s (expected us-central1)\n' "$RED" "$OFF" "'$loc'"; fail=$((fail+1))
fi
sa=$(jq -r '.gateways[0].serviceAccount' "$W/apigateway_inventory.json" 2>/dev/null)
if [ -n "$sa" ] && [ "$sa" != "null" ]; then
    printf '%s PASS%s discovery: gatewayServiceAccount resolved (%s)\n' "$GREEN" "$OFF" "$sa"; pass=$((pass+1))
else
    printf '%s FAIL%s discovery: gatewayServiceAccount empty\n' "$RED" "$OFF"; fail=$((fail+1))
fi
api=$(jq -r '.configs[0].api' "$W/apigateway_inventory.json" 2>/dev/null)
if [ "$api" = "apigw-healthy" ]; then
    printf '%s PASS%s discovery: config api id parsed (not "configs")\n' "$GREEN" "$OFF"; pass=$((pass+1))
else
    printf '%s FAIL%s discovery: config api id = %s\n' "$RED" "$OFF" "'$api'"; fail=$((fail+1))
fi

# The gateway identity must be normalized to the bare email. Real GCP returns it
# as projects/-/serviceAccounts/<email> while IAM members are
# serviceAccount:<email>; comparing those verbatim reports every correctly-bound
# gateway as missing its binding.
case "$sa" in
    */*) printf '%s FAIL%s discovery: serviceAccount not normalized (%s)\n' "$RED" "$OFF" "$sa"; fail=$((fail+1)) ;;
    *@*) printf '%s PASS%s discovery: serviceAccount normalized to bare email\n' "$GREEN" "$OFF"; pass=$((pass+1)) ;;
    *)   printf '%s FAIL%s discovery: serviceAccount unexpected (%s)\n' "$RED" "$OFF" "$sa"; fail=$((fail+1)) ;;
esac

# managedService is the only thing that scopes serviceruntime metrics to these
# gateways rather than to every Google API call in the project.
ms=$(jq -r '[.apis[]?.managedService | select(. != "")] | length' "$W/apigateway_inventory.json" 2>/dev/null)
if [ "${ms:-0}" -gt 0 ]; then
    printf '%s PASS%s discovery: managedService captured for %s api(s)\n' "$GREEN" "$OFF" "$ms"; pass=$((pass+1))
else
    printf '%s FAIL%s discovery: no managedService captured -- serviceruntime metrics cannot be scoped\n' "$RED" "$OFF"; fail=$((fail+1))
fi

assert_count "check_states       flags the FAILED ApiConfig"       "$W/resource_state_issues.json"   ge 1
assert_count "check_invoker      flags the missing run.invoker"    "$W/invoker_binding_issues.json"  ge 1
assert_count "check_config_drift flags the stale gateway pin"      "$W/config_drift_issues.json"     ge 1
assert_count "check_managed_svc  flags the disabled managed svc"   "$W/managed_service_issues.json"  ge 1
assert_count "check_backends     flags the dangling backend + 504s" "$W/backend_issues.json"         ge 2
assert_count "check_error_rates  flags high 5xx and 401/403"       "$W/error_rate_issues.json"       eq 2
assert_count "check_latency      flags high p95 and gateway gap"   "$W/latency_issues.json"          eq 2
assert_count "check_operations   flags the FAILED operation"       "$W/operations_issues.json"       eq 1

# The summary table must actually enumerate the gateways, not just exist.
if [ -f "$W/apigateway_summary_table.txt" ] && \
   grep -q "apigw-gw-noinv" "$W/apigateway_summary_table.txt"; then
    printf '%s PASS%s generate_summary   renders a table listing the gateways\n' "$GREEN" "$OFF"; pass=$((pass+1))
else
    printf '%s FAIL%s generate_summary   produced no usable summary table\n' "$RED" "$OFF"; fail=$((fail+1))
fi
rm -rf "$W"

echo
echo "=============================================================="
echo " Scenario: HEALTHY project -- every check must report NOTHING"
echo "=============================================================="
W=$(run_scenario healthy)
assert_count "check_states       clean"  "$W/resource_state_issues.json"   eq 0
assert_count "check_invoker      clean"  "$W/invoker_binding_issues.json"  eq 0
assert_count "check_config_drift clean"  "$W/config_drift_issues.json"     eq 0
assert_count "check_managed_svc  clean"  "$W/managed_service_issues.json"  eq 0
assert_count "check_backends     clean"  "$W/backend_issues.json"          eq 0
# Real metric data, comfortably inside every threshold -- a stronger check than
# an empty response, since it also proves these do not fire on healthy traffic.
assert_count "check_error_rates  clean on healthy traffic"  "$W/error_rate_issues.json"  eq 0
assert_count "check_latency      clean on healthy traffic"  "$W/latency_issues.json"     eq 0
assert_count "check_operations   clean"  "$W/operations_issues.json"       eq 0
rm -rf "$W"

echo
echo "=============================================================="
echo " Scenario: PUBLIC backend (allUsers) -- must not false-positive"
echo "=============================================================="
# A backend bound to allUsers is invokable by every principal including the
# gateway's service account, even though that account is not named in the
# policy. Reporting "missing run.invoker" here would be a false positive on any
# deliberately public backend.
W=$(run_scenario public)
assert_count "check_invoker      accepts allUsers as invoker" "$W/invoker_binding_issues.json" eq 0
rm -rf "$W"

echo
echo "=============================================================="
echo " Scenario: no managedService -- metric checks must not go"
echo "           project-wide"
echo "=============================================================="
# serviceruntime.googleapis.com/api/* spans every Google API call in the
# project. Queried on metric.type alone, a p95 reflects terraform's and other
# services' admin calls rather than gateway traffic, and alarms permanently in
# any active project. With nothing to scope to, the check must skip rather than
# report a project-wide number as gateway latency.
W=$(mktemp -d)
cp "$BUNDLE"/*.sh "$W"/
# stub curl here too: these checks are expected to skip before making any
# request, but if that logic ever breaks the suite must still not reach the
# network -- it would otherwise issue real Cloud Monitoring calls.
mkdir -p "$HERE/stub-path-noms"
ln -sf "$HERE/stub-gcloud" "$HERE/stub-path-noms/gcloud"
ln -sf "$HERE/stub-curl" "$HERE/stub-path-noms/curl"
(
    cd "$W" || exit 1
    export PATH="$HERE/stub-path-noms:$PATH" GCP_PROJECT_ID="stub-project" \
           STUB_SCENARIO="broken" GCP_REGIONS="us-central1"
    # inventory with apis but NO managedService on any of them
    cat > apigateway_inventory.json <<'INV'
{"project":"stub-project",
 "apis":[{"apiId":"apigw-healthy","state":"ACTIVE","managedService":""}],
 "configs":[],"gateways":[],"regions":["us-central1"]}
INV
    out=$(./check_latency.sh 2>&1)
    if echo "$out" | grep -q "Skipping latency analysis"; then
        printf '%s PASS%s check_latency  skips rather than measuring the whole project\n' "$GREEN" "$OFF"
    else
        printf '%s FAIL%s check_latency  did not skip without a managed service to scope to\n' "$RED" "$OFF"
    fi
    out=$(./check_error_rates.sh 2>&1)
    if echo "$out" | grep -q "skipping the 401/403 analysis"; then
        printf '%s PASS%s check_error_rates skips the unscoped 401/403 query\n' "$GREEN" "$OFF"
    else
        printf '%s FAIL%s check_error_rates ran the 401/403 query unscoped\n' "$RED" "$OFF"
    fi
) | tee "$W/.res"
pass=$((pass + $(grep -c 'PASS' "$W/.res" || true)))
fail=$((fail + $(grep -c 'FAIL' "$W/.res" || true)))
rm -rf "$W"

echo
echo "=============================================================="
echo " Scenario: TRANSIENT API FAILURE -- must fail, not answer"
echo "=============================================================="
# A failed query and an empty answer are different facts. When they were
# collapsed into a fallback value, one live run reported a healthy gateway as
# missing its invoker binding (false positive) AND skipped the genuinely broken
# one (false negative) -- while every task still reported PASS, because the
# script exited 0 and wrote a well-formed issues file.
#
# NOTE: the stub must exit NON-ZERO. A stub returning success-with-empty-data
# cannot express this case, and these assertions would be decorative.
W=$(mktemp -d)
cp "$BUNDLE"/*.sh "$W"/
mkdir -p "$HERE/stub-path-fail"
ln -sf "$HERE/stub-gcloud" "$HERE/stub-path-fail/gcloud"
ln -sf "$HERE/stub-curl" "$HERE/stub-path-fail/curl"
(
    cd "$W" || exit 1
    export PATH="$HERE/stub-path-fail:$PATH" GCP_PROJECT_ID="stub-project" \
           STUB_SCENARIO="broken" GCP_REGIONS="us-central1"
    ./discover_apigateway.sh >/dev/null 2>&1   # inventory built while healthy

    # 1) IAM policy read fails -> must NOT report "missing roles/run.invoker"
    rm -f invoker_binding_issues.json
    if STUB_FAIL="get-iam-policy" ./check_invoker_binding.sh >/dev/null 2>&1; then
        printf '%s FAIL%s check_invoker  exited 0 when the IAM policy read failed\n' "$RED" "$OFF"
    elif [ -f invoker_binding_issues.json ] && [ "$(jq 'length' invoker_binding_issues.json 2>/dev/null || echo 0)" -gt 0 ]; then
        printf '%s FAIL%s check_invoker  reported a finding from a failed IAM read\n' "$RED" "$OFF"
    else
        printf '%s PASS%s check_invoker  fails loudly when the IAM policy read fails\n' "$GREEN" "$OFF"
    fi

    # 2) ApiConfig describe fails -> must NOT report zero findings
    for c in check_invoker_binding check_backends; do
        f="invoker_binding_issues.json"; [ "$c" = "check_backends" ] && f="backend_issues.json"
        rm -f "$f"
        if STUB_FAIL="api-configs describe" ./"$c".sh >/dev/null 2>&1; then
            printf '%s FAIL%s %-22s exited 0 when the ApiConfig describe failed\n' "$RED" "$OFF" "$c"
        else
            printf '%s PASS%s %-22s fails loudly when the ApiConfig describe fails\n' "$GREEN" "$OFF" "$c"
        fi
    done

    # 3) Access token unobtainable -> must NOT silently skip the metric checks
    for c in check_latency check_error_rates check_operations check_backends; do
        if STUB_FAIL="print-access-token" ./"$c".sh >/dev/null 2>&1; then
            printf '%s FAIL%s %-22s exited 0 without an access token\n' "$RED" "$OFF" "$c"
        else
            printf '%s PASS%s %-22s fails loudly without an access token\n' "$GREEN" "$OFF" "$c"
        fi
    done
) | tee "$W/.res"
pass=$((pass + $(grep -c 'PASS' "$W/.res" || true)))
fail=$((fail + $(grep -c 'FAIL' "$W/.res" || true)))
rm -rf "$W"

echo
echo "=============================================================="
echo " Scenario: discovery NEVER RAN -- checks must fail, not pass"
echo "=============================================================="
# Regression guard for the SLI flow, which had no discovery step: with an
# empty-inventory fallback every check iterated nothing, reported zero issues
# and scored 1.0, so a broken project read as perfectly healthy. A check that
# cannot see the inventory must fail loudly instead.
W=$(mktemp -d)
cp "$BUNDLE"/*.sh "$W"/
mkdir -p "$HERE/stub-path-nodisc"
ln -sf "$HERE/stub-gcloud" "$HERE/stub-path-nodisc/gcloud"
ln -sf "$HERE/stub-curl" "$HERE/stub-path-nodisc/curl"
(
    cd "$W" || exit 1
    export PATH="$HERE/stub-path-nodisc:$PATH" GCP_PROJECT_ID="stub-project" \
           STUB_SCENARIO="broken" GCP_REGIONS="us-central1"
    for c in check_states check_config_drift check_invoker_binding check_managed_service check_backends; do
        # deliberately NO discover_apigateway.sh
        if ./"$c".sh >/dev/null 2>&1; then
            printf '%s FAIL%s %-22s exited 0 without an inventory (would score healthy)\n' "$RED" "$OFF" "$c"
        else
            printf '%s PASS%s %-22s fails loudly without an inventory\n' "$GREEN" "$OFF" "$c"
        fi
    done
) | tee "$W/.res"
pass=$((pass + $(grep -c 'PASS' "$W/.res" || true)))
fail=$((fail + $(grep -c 'FAIL' "$W/.res" || true)))
rm -rf "$W"

rm -rf "$HERE"/stub-path-*
echo
echo "--------------------------------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
