#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Offline assertion tier for gcp-apigee-environment-health.
#
# Runs all eight scripts against canned Apigee API responses -- no cloud, no
# credentials, no spend -- and ASSERTS on what they report. Exits non-zero if
# any assertion fails, so it can gate a PR.
#
# Every assertion below corresponds to a defect found during PR #745 review.
# This tier cannot catch anything that depends on real API behaviour not
# encoded in the fixtures (H5, a duplicate multipart part name, needed a live
# API); it complements the live run, it does not replace it.
#
#   ./run.sh          run every scenario
#   ./run.sh -v       also echo each script's stdout on failure
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${HERE}/../.." && pwd)"
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

CHECKS="check_org_env_state check_instance_attachments check_envgroup_attachments
        check_keystore_cert_expiry check_target_servers check_instance_capacity
        check_southbound_connectivity"

# scenario <name> <fixture-dir>  -- runs discovery + every check in a clean dir
scenario() {
    local name="$1" fixtures="$2"
    printf '\n%s== %s%s\n' "${BLUE}" "${name}" "${NC}"
    rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
    export PATH="${HERE}/bin:${PATH}"
    export FIXTURES="${fixtures}"
    export GCP_PROJECT_ID="test-project"
    export ENVIRONMENTS="All"
    export CERT_EXPIRY_WARNING_DAYS=30
    export TARGET_REACHABILITY_TIMEOUT=1
    # Left empty on purpose: exercises the D1 discovery fallback every run.
    export APIGEE_ORG=""

    bash "${BUNDLE}/discover_topology.sh" > discover.log 2>&1
    DISCOVER_RC=$?
    for s in ${CHECKS}; do
        bash "${BUNDLE}/${s}.sh" > "${s}.log" 2>&1
        eval "RC_${s}=\$?"
    done
}

# rc <script>  -- exit code recorded by scenario()
rc() { eval "echo \"\${RC_$1}\""; }
# issues <file> -- issue count, or -1 when the file is missing entirely
issues() { [ -f "$1" ] && jq 'length' "$1" 2>/dev/null || echo -1; }
titles() { [ -f "$1" ] && jq -r '[.[].title] | join(" | ")' "$1" 2>/dev/null || echo ""; }

# --- Fixture variants ---------------------------------------------------------
# `main` is the baseline; the two variants differ ONLY in the organization
# document, so a difference in outcome can only come from the org fields.
prepare_fixtures() {
    bash "${HERE}/fixtures.sh" "${HERE}/fixtures/main" >/dev/null

    rm -rf "${HERE}/fixtures/nopeer"; cp -R "${HERE}/fixtures/main" "${HERE}/fixtures/nopeer"
    cat > "${HERE}/fixtures/nopeer/organizations_test-org.json" <<'EOF'
{"name":"test-org","state":"ACTIVE","runtimeType":"CLOUD","disableVpcPeering":true}
EOF

    rm -rf "${HERE}/fixtures/nonet"; cp -R "${HERE}/fixtures/main" "${HERE}/fixtures/nonet"
    cat > "${HERE}/fixtures/nonet/organizations_test-org.json" <<'EOF'
{"name":"test-org","state":"ACTIVE","runtimeType":"CLOUD","disableVpcPeering":false}
EOF
}
prepare_fixtures

# =============================================================================
scenario "Scenario A -- healthy org, APIGEE_ORG unset" "${HERE}/fixtures/main"

assert_eq "discovery exits 0" "${DISCOVER_RC}" "0"
for s in ${CHECKS}; do assert_eq "${s} exits 0" "$(rc "${s}")" "0"; done

# -- D1: org resolved from the dump when APIGEE_ORG is empty
assert_eq "D1  org resolved from topology" \
    "$(jq -r '.org.name' apigee_topology.json)" "test-org"

# -- D3: a real JSON array of environments survives discovery
assert_eq "D3  both environments preserved" \
    "$(jq -r '.environments | length' apigee_topology.json)" "2"

# -- H2: envgroup attachments read from environmentGroupAttachments
assert_eq "H2  attached envgroup resolved" \
    "$(jq -rc '.envgroup_attachments["eg-main"]' apigee_topology.json)" '["env-a"]'

# -- H3: org network from authorizedNetwork, range from the instances
assert_eq "H3  org network resolved" \
    "$(jq -r '.org.network' apigee_topology.json)" "apigee-net"
assert_eq "H3  peering range from instances" \
    "$(jq -r '.org.peering_cidr_range' apigee_topology.json)" "SLASH_22"

printf '  %sknown-positive -- each seeded fault must be reported%s\n' "${DIM}" "${NC}"
assert_has "unattached environment detected" \
    "$(titles instance_attachment_issues.json)" "env-b"
assert_has "orphan envgroup detected" \
    "$(titles envgroup_attachment_issues.json)" "eg-orphan"
assert_eq  "expiring certificate detected" \
    "$(issues keystore_cert_issues.json)" "1"
assert_has "disabled target server detected" \
    "$(titles target_server_issues.json)" "is disabled"
assert_has "dangling target host detected" \
    "$(titles target_server_issues.json)" "unresolvable host"

printf '  %sknown-negative -- healthy fixtures must NOT be reported%s\n' "${DIM}" "${NC}"
assert_hasnt "H2  attached envgroup not flagged" \
    "$(titles envgroup_attachment_issues.json)" "eg-main"
assert_eq "org/env state clean" "$(issues org_env_state_issues.json)" "0"
assert_eq "H3  southbound clean" "$(issues southbound_issues.json)" "0"
assert_eq "discovery reported no issues" "$(issues discovery_issues.json)" "0"

# =============================================================================
# D2: a degraded {} dump must not crash the checks, and must not be silently
# indistinguishable from healthy -- every check still has to write a file.
scenario "Scenario B -- degraded {} topology" "${HERE}/fixtures/main"
cd "${WORK}" || exit 1
echo '{}' > apigee_topology.json
echo '[{"title":"discovery failed"}]' > discovery_issues.json
for s in ${CHECKS}; do
    bash "${BUNDLE}/${s}.sh" > "${s}.log" 2>&1
    eval "RC_${s}=\$?"
done
for s in ${CHECKS}; do assert_eq "D2  ${s} exits 0" "$(rc "${s}")" "0"; done
for f in org_env_state instance_attachment envgroup_attachment keystore_cert \
         target_server capacity southbound; do
    assert_eq "D2  ${f}_issues.json written and empty" "$(issues "${f}_issues.json")" "0"
done

# =============================================================================
# An org provisioned with disableVpcPeering has no authorizedNetwork BY DESIGN
# and must not be flagged for it.
scenario "Scenario C -- disableVpcPeering=true" "${HERE}/fixtures/nopeer"
assert_eq "southbound skipped, not flagged" "$(issues southbound_issues.json)" "0"
assert_has "skip is stated in the log" "$(cat check_southbound_connectivity.log)" "without VPC peering"

# =============================================================================
# ...but a genuinely missing network with peering enabled must still fire, so
# the skip above cannot mask a real misconfiguration.
scenario "Scenario D -- no network, peering enabled" "${HERE}/fixtures/nonet"
assert_eq "missing network still flagged" "$(issues southbound_issues.json)" "1"
assert_has "flagged for authorizedNetwork" \
    "$(titles southbound_issues.json)" "no VPC network configured"

# =============================================================================
# The shared-org credential contract. No cloud needed: this is pure resolution
# logic, and it is where the three bundles previously drifted apart.
printf '\n%s== Scenario E -- credential contract (load-credentials.sh)%s\n' "${BLUE}" "${NC}"
LC="${BUNDLE}/.test/load-credentials.sh"
CRED_WORK="${WORK}-cred"
rm -rf "${CRED_WORK}"; mkdir -p "${CRED_WORK}/terraform"

# Run the loader in a subshell with a fake .test layout, so `exit 1` from the
# sourced script is observable rather than killing this runner.
try_load() {
    ( cd "${CRED_WORK}" && env -u APIGEE_ORG -u GCP_PROJECT_ID \
        bash -c ". '${CRED_WORK}/load-credentials.sh'; echo \"ORG=\${APIGEE_ORG} PROJECT=\${GCP_PROJECT_ID}\"" 2>&1 )
}
cp "${LC}" "${CRED_WORK}/load-credentials.sh"

# P1.1: no credential file at all must fail, not warn.
rm -f "${CRED_WORK}/terraform/tf.secret" "${CRED_WORK}/tf.secret"
out="$(try_load)"; rcv=$?
assert_eq  "P1.1 missing credential file exits non-zero" "$([ "${rcv}" -ne 0 ] && echo fail || echo pass)" "fail"
assert_has "P1.1 names the expected path" "${out}" "terraform/tf.secret"
assert_has "P1.1 points at the offline tier" "${out}" "task test-offline"

# TF_VAR_org_id in resource-name form resolves to the bare name.
cat > "${CRED_WORK}/terraform/tf.secret" <<'EOF'
export TF_VAR_org_id="organizations/shared-org"
export TF_VAR_project_id="shared-project"
EOF
assert_has "TF_VAR_org_id: organizations/ prefix stripped" "$(try_load)" "ORG=shared-org "
assert_has "TF_VAR_project_id resolved"                    "$(try_load)" "PROJECT=shared-project"

# The sibling bundles' spelling resolves identically.
cat > "${CRED_WORK}/terraform/tf.secret" <<'EOF'
export APIGEE_ORG="shared-org"
export GCP_PROJECT_ID="shared-project"
EOF
assert_has "APIGEE_ORG (sibling spelling) resolves the same" "$(try_load)" "ORG=shared-org "

# A file naming neither must fail rather than proceed with an empty org.
cat > "${CRED_WORK}/terraform/tf.secret" <<'EOF'
export TF_VAR_region="us-west1"
EOF
out="$(try_load)"; rcv=$?
assert_eq  "credential file naming no org exits non-zero" "$([ "${rcv}" -ne 0 ] && echo fail || echo pass)" "fail"
assert_has "says which variables it looked for" "${out}" "TF_VAR_org_id"

# Canonical location wins over the legacy one.
cat > "${CRED_WORK}/terraform/tf.secret" <<'EOF'
export APIGEE_ORG="canonical-org"
export GCP_PROJECT_ID="p"
EOF
cat > "${CRED_WORK}/tf.secret" <<'EOF'
export APIGEE_ORG="legacy-org"
export GCP_PROJECT_ID="p"
EOF
assert_has "canonical terraform/tf.secret takes precedence" "$(try_load)" "ORG=canonical-org "
rm -rf "${CRED_WORK}"

# =============================================================================
cd "${HERE}" || exit 1
printf '\n%s== summary%s\n' "${BLUE}" "${NC}"
printf '  %s%d passed%s, %s%d failed%s\n' "${GREEN}" "${PASS}" "${NC}" \
    "$([ "${FAIL}" -gt 0 ] && echo "${RED}" || echo "${GREEN}")" "${FAIL}" "${NC}"
if [ "${FAIL}" -gt 0 ]; then
    printf '  logs: %s\n' "${WORK}"
    [ "${VERBOSE}" = "-v" ] && for f in "${WORK}"/*.log; do printf '\n--- %s\n' "$f"; cat "$f"; done
    exit 1
fi
rm -rf "${WORK}"
exit 0
