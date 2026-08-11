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

# -----------------------------------------------------------------------------
# Issue identity: a title is the key the platform tracks an issue by, so it must
# describe the PROBLEM CLASS and nothing that varies between runs. This SLX is
# project-scoped, so N resources with one fault is one occurrence of that fault
# -- resource ids, states and counts belong in details/actual.
#
# Asserted by construction: no title may contain any identifier from the
# inventory. That catches the whole family (per-resource titles, embedded
# counts, embedded states) without hardcoding what the titles should say.
# -----------------------------------------------------------------------------
ids=$(jq -r '[.apis[]?.apiId, .gateways[]?.gatewayId, .configs[]?.configId]
             | map(select(. != null and . != "")) | .[]' \
      "$W/apigateway_inventory.json" 2>/dev/null | sort -u)
titles=$(cat "$W"/*_issues.json 2>/dev/null | jq -r '.[]?.title // empty' | sort -u)
bad=0
while IFS= read -r t; do
    [ -z "$t" ] && continue
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        case "$t" in
            *"$id"*) printf '%s FAIL%s issue title carries resource id `%s`: %s\n' "$RED" "$OFF" "$id" "$t"; bad=$((bad+1)) ;;
        esac
    done <<< "$ids"
done <<< "$titles"
if [ "$bad" -eq 0 ]; then
    printf '%s PASS%s issue titles carry no resource identifier (%s distinct title(s))\n' \
        "$GREEN" "$OFF" "$(printf '%s\n' "$titles" | grep -c .)"; pass=$((pass+1))
else
    fail=$((fail+bad))
fi

# The same problem must keep the same title however many resources it affects,
# so counts must not appear either. Checked against the counts actually present.
counts=$(cat "$W"/*_issues.json 2>/dev/null | jq -r '.[]?.actual // empty' | grep -oE '^[0-9]+' | sort -u)
badn=0
while IFS= read -r c; do
    [ -z "$c" ] && continue
    while IFS= read -r t; do
        case "$t" in
            *" $c "*|*" $c"*) printf '%s FAIL%s issue title carries a count (%s): %s\n' "$RED" "$OFF" "$c" "$t"; badn=$((badn+1)) ;;
        esac
    done <<< "$titles"
done <<< "$counts"
if [ "$badn" -eq 0 ]; then
    printf '%s PASS%s issue titles carry no affected-resource count\n' "$GREEN" "$OFF"; pass=$((pass+1))
else
    fail=$((fail+badn))
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

echo
echo "=============================================================="
echo " Scenario: NO TRAFFIC -- must report unmeasured, not healthy"
echo "=============================================================="
# A gateway that exists but has served nothing produces no metric data. Scoring
# that as 1.0 hands a silent gateway the same 0.25 of the composite (0.15 error
# + 0.10 latency) as one serving flawlessly. The checks must say they measured
# nothing so the aggregate can exclude the dimension and renormalise.
W=$(mktemp -d)
cp "$BUNDLE"/*.sh "$W"/
mkdir -p "$HERE/stub-path-notraffic"
ln -sf "$HERE/stub-gcloud" "$HERE/stub-path-notraffic/gcloud"
ln -sf "$HERE/stub-curl" "$HERE/stub-path-notraffic/curl"
(
    cd "$W" || exit 1
    export PATH="$HERE/stub-path-notraffic:$PATH" GCP_PROJECT_ID="stub-project" \
           STUB_SCENARIO="healthy" GCP_REGIONS="us-central1" STUB_NO_TRAFFIC=1
    ./discover_apigateway.sh >/dev/null 2>&1
    for c in check_latency:latency check_error_rates:error_rate; do
        s=${c%%:*}; m=${c##*:}
        ./"$s".sh >/dev/null 2>&1
        got=$(cat "${m}_measured" 2>/dev/null || echo MISSING)
        n=$(jq 'length' "${m}_issues.json" 2>/dev/null || echo -1)
        if [ "$got" = "false" ] && [ "$n" = "0" ]; then
            printf '%s PASS%s %-18s reports unmeasured (0 issues, measured=false)\n' "$GREEN" "$OFF" "$s"
        else
            printf '%s FAIL%s %-18s measured=%s issues=%s (want false/0)\n' "$RED" "$OFF" "$s" "$got" "$n"
        fi
    done
    # and with traffic, the same checks must report they DID measure
    unset STUB_NO_TRAFFIC
    for c in check_latency:latency check_error_rates:error_rate; do
        s=${c%%:*}; m=${c##*:}
        ./"$s".sh >/dev/null 2>&1
        got=$(cat "${m}_measured" 2>/dev/null || echo MISSING)
        if [ "$got" = "true" ]; then
            printf '%s PASS%s %-18s reports measured=true when traffic exists\n' "$GREEN" "$OFF" "$s"
        else
            printf '%s FAIL%s %-18s measured=%s with traffic present (want true)\n' "$RED" "$OFF" "$s" "$got"
        fi
    done
) | tee "$W/.res"
pass=$((pass + $(grep -c 'PASS' "$W/.res" || true)))
fail=$((fail + $(grep -c 'FAIL' "$W/.res" || true)))
rm -rf "$W"

echo
echo "=============================================================="
echo " Scenario: API DISABLED / list fails -- must not look healthy"
echo "=============================================================="
# With interactive prompts disabled (as they must be, or gcloud blocks on stdin
# until the task times out), a disabled API makes the list calls fail FAST. If
# that failure is swallowed into "[]", discovery publishes an empty inventory,
# every check iterates nothing, and the SLI scores a perfect 1.0 for a project
# whose API Gateway API is not even enabled. That is strictly worse than the
# timeout it replaced, because the timeout at least failed loudly.
W=$(mktemp -d)
cp "$BUNDLE"/*.sh "$W"/
mkdir -p "$HERE/stub-path-disabled"
ln -sf "$HERE/stub-gcloud" "$HERE/stub-path-disabled/gcloud"
ln -sf "$HERE/stub-curl" "$HERE/stub-path-disabled/curl"
(
    cd "$W" || exit 1
    export PATH="$HERE/stub-path-disabled:$PATH" GCP_PROJECT_ID="stub-project" \
           STUB_SCENARIO="broken" GCP_REGIONS="us-central1"

    out=$(STUB_FAIL="api-gateway" STUB_FAIL_REASON="disabled" ./discover_apigateway.sh 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s FAIL%s discovery      exited 0 when every list call failed\n' "$RED" "$OFF"
    elif [ -f apigateway_inventory.json ]; then
        printf '%s FAIL%s discovery      published an inventory from failed list calls\n' "$RED" "$OFF"
    else
        printf '%s PASS%s discovery      fails loudly when the API is disabled\n' "$GREEN" "$OFF"
    fi
    if printf '%s' "$out" | grep -q "gcloud services enable apigateway.googleapis.com"; then
        printf '%s PASS%s discovery      names the disabled API and how to enable it\n' "$GREEN" "$OFF"
    else
        printf '%s FAIL%s discovery      gave no actionable reason for the failure\n' "$RED" "$OFF"
    fi

) | tee "$W/.res"
pass=$((pass + $(grep -c 'PASS' "$W/.res" || true)))
fail=$((fail + $(grep -c 'FAIL' "$W/.res" || true)))
rm -rf "$W"

echo
echo "=============================================================="
echo " Robot guards: every check must be pre-cleaned and exit-checked"
echo "=============================================================="
# The working directory is REUSED between runs, so output from a previous run
# survives into the next one. The parse guard ("refusing to report no issues for
# a check that never ran") is then blind: a stale file still parses, so a failed
# check is reported as the previous run's result. A stale *clean* file is the
# dangerous direction -- it hides the very condition this bundle detects, while
# reporting all tasks passed.
#
# Asserted statically against the real robot files rather than a synthetic copy,
# so adding a task without the guards fails here. Needs only bash + grep.
for rf in "$BUNDLE"/runbook.robot "$BUNDLE"/sli.robot; do
    name=$(basename "$rf")
    total=$(grep -c "RW.CLI.Run Bash File" "$rf")
    guarded=0; cleaned=0
    while read -r ln; do
        # a returncode guard must follow within the block that reads its output
        if sed -n "$((ln+1)),$((ln+14))p" "$rf" | grep -q 'returncode != 0'; then
            guarded=$((guarded+1))
        else
            printf '%s FAIL%s %s:%s Run Bash File with no returncode guard\n' "$RED" "$OFF" "$name" "$ln"
        fi
        # and a pre-clean must precede it
        if sed -n "$((ln>10 ? ln-10 : 1)),$((ln-1))p" "$rf" | grep -q 'cmd=rm -f'; then
            cleaned=$((cleaned+1))
        else
            printf '%s FAIL%s %s:%s Run Bash File with no pre-clean of prior output\n' "$RED" "$OFF" "$name" "$ln"
        fi
    done < <(grep -n "RW.CLI.Run Bash File" "$rf" | cut -d: -f1)

    if [ "$guarded" -eq "$total" ]; then
        printf '%s PASS%s %-16s all %s check(s) fail on non-zero exit\n' "$GREEN" "$OFF" "$name" "$total"; pass=$((pass+1))
    else
        printf '%s FAIL%s %-16s only %s/%s checks exit-guarded\n' "$RED" "$OFF" "$name" "$guarded" "$total"; fail=$((fail+1))
    fi
    if [ "$cleaned" -eq "$total" ]; then
        printf '%s PASS%s %-16s all %s check(s) pre-clean stale output\n' "$GREEN" "$OFF" "$name" "$total"; pass=$((pass+1))
    else
        printf '%s FAIL%s %-16s only %s/%s checks pre-clean\n' "$RED" "$OFF" "$name" "$cleaned" "$total"; fail=$((fail+1))
    fi
done

rm -rf "$HERE"/stub-path-*
echo
echo "--------------------------------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
