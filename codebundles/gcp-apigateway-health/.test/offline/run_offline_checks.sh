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
    export GCP_PROJECT_ID="stub-project"
    export STUB_SCENARIO="$scen"
    export GCP_REGIONS="us-central1"

    ./discover_apigateway.sh   >/dev/null 2>&1
    ./check_states.sh          >/dev/null 2>&1
    ./check_invoker_binding.sh >/dev/null 2>&1
    ./check_config_drift.sh    >/dev/null 2>&1
    ./check_managed_service.sh >/dev/null 2>&1
    ./check_backends.sh        >/dev/null 2>&1

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

assert_count "check_states       flags the FAILED ApiConfig"       "$W/resource_state_issues.json"   ge 1
assert_count "check_invoker      flags the missing run.invoker"    "$W/invoker_binding_issues.json"  ge 1
assert_count "check_config_drift flags the stale gateway pin"      "$W/config_drift_issues.json"     ge 1
assert_count "check_managed_svc  flags the disabled managed svc"   "$W/managed_service_issues.json"  ge 1
assert_count "check_backends     flags the dangling backend"       "$W/backend_issues.json"          ge 1
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
rm -rf "$W"

rm -rf "$HERE"/stub-path-*
echo
echo "--------------------------------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
