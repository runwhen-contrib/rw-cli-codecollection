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
# Whole issue body -- titles are now failure-mode only, so anything asserting on
# a resource name has to look at details/actual as well.
bodies() { [ -f "$1" ] && jq -r '[.[] | .title, .actual, .details] | join(" ")' "$1" 2>/dev/null || echo ""; }

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

# The org list is ordered decoy-first, so this fails if selection is positional
# rather than by projectId. Picking the decoy would not error -- it is a real
# org that answers -- so every downstream check would silently describe the
# wrong project.
assert_eq "org selected by projectId, not by position" \
    "$(jq -r '.org.name' apigee_topology.json)" "test-org"
assert_hasnt "decoy org from another project not selected" \
    "$(jq -r '.org.name' apigee_topology.json)" "decoy"

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
# Resource names live in details/actual now, not in titles, so presence checks
# read the whole issue body. Titles are asserted separately to be static.
assert_has "unattached environment detected" \
    "$(bodies instance_attachment_issues.json)" "env-b"
assert_has "orphan envgroup detected" \
    "$(bodies envgroup_attachment_issues.json)" "eg-orphan"
assert_eq  "expiring certificate detected" \
    "$(issues keystore_cert_issues.json)" "1"
assert_has "disabled target server detected" \
    "$(titles target_server_issues.json)" "are disabled"
assert_has "dangling target host detected" \
    "$(titles target_server_issues.json)" "unresolvable host"

printf '  %sissue titles: failure mode + org scope only%s\n' "${DIM}" "${NC}"
# A title may name the SLX's own scope: there is exactly one per SLX and it
# never changes, so it costs no churn and tells an operator which SLX fired. It
# must NOT name a CONTAINED resource, of which there are many and which come
# and go, nor any changing number.
#
# The scope is the ORG, not the project -- the rule gates on
# gcp_apigee_organizations, so labelling an org-anchored finding "in project X"
# named the wrong thing. Three shapes are legitimate:
#
#   ... in org `test-org`                          a contained resource failed
#   Apigee organization `test-org` is not ACTIVE   the org ITSELF is the subject
#   ... in project `test-project`                  discovery only: the org is
#                                                  precisely what could not be
#                                                  determined, so the project is
#                                                  the only identifier there is
#
# Scope is stripped before the checks below, so the org name does not count as
# a contained-resource name -- otherwise the guard would fire on the very thing
# being added. The org is stripped only where it is backticked; an unquoted
# mention would still trip the resource-name check.
strip_scope() {
    jq -r '[.[].title
            | gsub(" in org `[^`]*`"; "")
            | gsub("`test-org`"; "")
            | gsub(" in project `[^`]*`"; "")]'
}
for f in org_env_state instance_attachment envgroup_attachment keystore_cert \
         target_server capacity southbound discovery; do
    [ -f "${f}_issues.json" ] || continue
    assert_eq "${f}: every title names the org scope (or the project when the org is unknown)" \
        "$(jq -r '[.[].title | select(test("`test-org`|in project `[^`]+`") | not)] | length' "${f}_issues.json")" "0"
    assert_eq "${f}: no contained resource name in any title" \
        "$(strip_scope < "${f}_issues.json" | jq -r '[.[] | select(test("env-[ab]|eg-(main|orphan)|ts-1|inst-[12]|test-org"))] | length')" "0"
    assert_eq "${f}: no digits outside the scope" \
        "$(strip_scope < "${f}_issues.json" | jq -r '[.[] | select(test("[0-9]"))] | length')" "0"
done

printf '  %sknown-negative -- healthy fixtures must NOT be reported%s\n' "${DIM}" "${NC}"
# Checked against the whole body: titles no longer contain names, so asserting
# absence from the title alone would pass no matter what.
assert_hasnt "H2  attached envgroup not flagged" \
    "$(bodies envgroup_attachment_issues.json)" "eg-main"
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
# Missing inventory is an ERROR, not an empty environment. Discovery now runs in
# Suite Initialization and fails the suite when it cannot produce a topology, so
# a check that finds no file has been run against nothing and must say so rather
# than reporting "no issues found".
printf '\n%s== Scenario I -- topology file absent (must error, not report clean)%s\n' "${BLUE}" "${NC}"
rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}" || exit 1
export PATH="${HERE}/bin:${PATH}"
export FIXTURES="${HERE}/fixtures/main" GCP_PROJECT_ID="test-project" ENVIRONMENTS="All"
export CERT_EXPIRY_WARNING_DAYS=30 TARGET_REACHABILITY_TIMEOUT=1 APIGEE_ORG=""
for s in ${CHECKS}; do
    bash "${BUNDLE}/${s}.sh" > "${s}.log" 2>&1
    rc_missing=$?
    assert_eq "${s} exits non-zero" "$([ "${rc_missing}" -ne 0 ] && echo error || echo clean)" "error"
    assert_eq "${s} wrote no misleading empty result" \
        "$([ -f "${s#check_}_issues.json" ] || [ -f capacity_issues.json ] && echo wrote || echo none)" "none"
done

# =============================================================================
# An org with NO runtime instances must produce ONE finding naming the cause,
# not one per environment restating it.
prepare_noinstances() {
    rm -rf "${HERE}/fixtures/noinst"; cp -R "${HERE}/fixtures/main" "${HERE}/fixtures/noinst"
    echo '{"instances":[]}' > "${HERE}/fixtures/noinst/organizations_test-org_instances.json"
}
prepare_noinstances
scenario "Scenario J -- org with zero runtime instances" "${HERE}/fixtures/noinst"
assert_eq  "capacity reports the cause once" "$(issues capacity_issues.json)" "1"
assert_has "and names it"                    "$(titles capacity_issues.json)" "no runtime instances"
assert_eq  "attachment check defers, adds no duplicates" "$(issues instance_attachment_issues.json)" "0"

# =============================================================================
# The generation rule now gates on gcp_apigee_organizations, so an SLX only
# exists where an organization is indexed. Absence can no longer occur and the
# scenarios that covered it are gone. Failure to determine still can, and must
# still fail loudly -- that is the one this tier keeps.
prepare_org_list_fixture() {
    # $1 = target dir, $2 = HTTP status the stub should report, $3 = body
    rm -rf "$1"; cp -R "${HERE}/fixtures/main" "$1"
    printf '%s' "$3" > "$1/organizations.json"
    printf '%s' "$2" > "$1/.status_organizations"
}

# Permission denied: we could not tell which org applies. Must still fail, and
# must NOT quietly proceed against whatever org happens to be visible.
prepare_org_list_fixture "${HERE}/fixtures/denied" 403 \
  '{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Caller lacks apigee.organizations.list"}}'
scenario "Scenario H -- permission denied (could NOT determine)" "${HERE}/fixtures/denied"
assert_eq   "raises a discovery issue"  "$(issues discovery_issues.json)" "1"
assert_has  "issue distinguishes itself from absence" "$(titles discovery_issues.json)" "Cannot determine"

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

# go-task runs tasks through mvdan.cc/sh, where BASH_SOURCE does not exist:
# `dirname "${BASH_SOURCE[0]}"` becomes "." and silently resolves to the
# caller's working directory, so tasks with `dir: terraform` search one level
# too deep. This tier runs under bash, where that bug is INVISIBLE -- every
# behavioural assertion below still passed while it was live. A static check is
# the only thing here that can catch a regression.
# Comments are stripped first: the file explains the trap in prose, and matching
# that would fail on the documentation rather than on real usage.
assert_eq  "no BASH_SOURCE in executable lines (unset in go-task's shell)" \
    "$(grep -v '^[[:space:]]*#' "${LC}" | grep -c 'BASH_SOURCE' | xargs)" "0"
assert_has "locates itself by probing for the script" "$(cat "${LC}")" 'load-credentials.sh" ]'

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
# Runbook wiring that this tier cannot exercise behaviourally -- it runs the
# scripts directly, never `robot` -- so it is checked statically instead.
printf '\n%s== Scenario K -- runbook wiring (static)%s\n' "${BLUE}" "${NC}"
RB="${BUNDLE}/runbook.robot"

# APIGEE_ORG now arrives from the SLX, because the rule gates on the org and the
# matched resource IS it. Resolving it at run time is what the previous version
# did, and it could not work: task names are substituted from config_provided,
# not from Robot suite variables.
GR="${BUNDLE}/.runwhen/generation-rules/gcp-apigee-environment-health.yaml"
# Comments are stripped first. The rule's own commentary names the resource
# type, so matching the whole file passed even with the gate reverted to
# `project` -- an assertion that could not fail.
GR_CODE="$(grep -v '^ *#' "${GR}")"
assert_has "generation rule gates on the Apigee organization" \
    "${GR_CODE}" "gcp_apigee_organizations"
assert_hasnt "  ...and no longer on bare project" \
    "${GR_CODE}" "- project"
# Checked against the code, not the whole file: the rule's commentary quotes
# both qualifier forms while explaining the choice.
assert_has "  ...anchored on the organization" \
    "${GR_CODE}" 'qualifiers: ["resource"]'
# runwhen-local's gcp-hierarchy.yaml only inserts project_id into the path when
# `resource` is a qualifier, so reverting to ["project"] silently flattens
# resourcePath from gcp/<project>/<org> to gcp/<project>.
assert_hasnt "  ...not flattened back to the project" \
    "${GR_CODE}" 'qualifiers: ["project"]'
for t in slx taskset; do
    # Comments stripped, same reason as the generation rule above: the block
    # explaining why NOT to reach through match_resource.resource.name contains
    # that very string, so matching the whole file would pass no matter what
    # the template actually does.
    TPL="$(grep -v '^ *#' "${BUNDLE}/.runwhen/templates/gcp-apigee-environment-health-${t}.yaml")"
    assert_has "${t} template supplies APIGEE_ORG from the matched org" \
        "${TPL}" "match_resource.resource"
    # shellcheck disable=SC2016
    assert_has "${t}: APIGEE_ORG is the resolved org, not an inline expression" \
        "${TPL}" "value: '{{apigee_org}}'"
    # BOOLEAN mode is the whole point. Plain default() substitutes only for an
    # UNDEFINED value, so a workspaceInfo carrying `apigee_org: ""` renders
    # APIGEE_ORG empty and skips every fallback -- which is how it came out
    # empty on a live workspace while the resource_name tag was populated.
    # shellcheck disable=SC2016
    assert_has "${t}: org fallback is in boolean mode, not undefined-only" \
        "${TPL}" 'default(_res.name, true)'
    # The indexed payload must be materialised before its fields are read.
    # CustomUndefined subclasses plain Undefined, whose __getattr__ RAISES, so
    # reaching through match_resource.resource.name aborts the whole render
    # with UndefinedError when .resource is absent rather than falling through.
    # shellcheck disable=SC2016
    assert_has "${t}: indexed payload is materialised before use" \
        "${TPL}" 'match_resource.resource | default({}, true)'
    assert_hasnt "${t}: never reaches through .resource.name in an expression" \
        "${TPL}" 'default(match_resource.resource.name'
    # gcp-tags.yaml renders the resource_name tag from qualifiers.resource, so
    # sharing that source is what stops the tag and APIGEE_ORG disagreeing.
    # shellcheck disable=SC2016
    assert_has "${t}: org falls back to the same source as the resource_name tag" \
        "${TPL}" 'default(qualifiers.resource, true)'
    # The closing paren is what makes this precise: the boolean-mode form is
    # `...name, true)`, so this matches only the undefined-only variant.
    # shellcheck disable=SC2016
    assert_hasnt "${t}: no bare undefined-only default left on the org" \
        "${TPL}" 'default(match_resource.resource.name)'
done

# The SLX is anchored on the org, so the scope tag and task titles must say so.
assert_has "SLX scope tag is the organization, not the project" \
    "$(cat "${BUNDLE}/.runwhen/templates/gcp-apigee-environment-health-slx.yaml")" \
    "value: organization"
TASK_TITLES="$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\*/{f=0} f && /^[^ \t]/ && NF' "${RB}")"
# shellcheck disable=SC2016
assert_eq "every task title names the org" \
    "$(printf '%s\n' "${TASK_TITLES}" | grep -c 'in `${APIGEE_ORG}`')" "7"
assert_eq "no task title still names the project" \
    "$(printf '%s\n' "${TASK_TITLES}" | grep -c 'GCP_PROJECT_ID' || true)" "0"
assert_hasnt "runbook no longer resolves the org at run time" \
    "$(cat "${RB}")" "resolved_org"

# Discovery must fail the suite when it could not read a topology, so the seven
# checks are not attempted rather than passing with nothing found.
assert_has "discovery failure fails the suite" \
    "$(cat "${RB}")" "Fail    Apigee topology discovery failed"
# Auth gates on whether a token can be minted, not on whether activation
# succeeded. Gating on the activation exit code took the whole suite down on a
# runner whose ambient identity was fine (all 7 tasks NOT RUN), because gcloud
# misread the key file as a .p12. Activation stays tolerant; the token probe
# does not, so a run with no identity at all still cannot report green.
#
# The single quotes below are load-bearing, not a style slip: these are Robot
# ${...} literals to match verbatim. Letting the shell expand them yields an
# empty needle, which every assert_has then "passes" against. SC2016 is exactly
# backwards here, so it is disabled per assertion rather than fixed.
# shellcheck disable=SC2016
assert_has "activation is tolerant" \
    "$(cat "${RB}")" 'activate-service-account --key-file="./${gcp_credentials.key}" || true'
# Match the gate itself, not the bare token sentinel: TOKEN_ABSENT also appears
# in the probe's own `echo`, so asserting the word alone survives deleting the IF.
# shellcheck disable=SC2016
assert_has "the token probe is what gates the suite" \
    "$(cat "${RB}")" 'IF    "TOKEN_ABSENT" in """${token.stdout}"""'
assert_has "no obtainable token fails the suite" \
    "$(cat "${RB}")" "Fail    Could not obtain a GCP access token"
# shellcheck disable=SC2016
assert_hasnt "the suite does not gate on the activation returncode" \
    "$(cat "${RB}")" 'IF    ${auth.returncode} != 0'
assert_eq "discovery is NOT a task" \
    "$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\*/{f=0} f && /^[^ \t]/ && NF' "${RB}" | grep -c '^Discover')" "0"
assert_eq "seven check tasks remain" \
    "$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\*/{f=0} f && /^[^ \t]/ && NF' "${RB}" | wc -l | xargs)" "7"
# shellcheck disable=SC2016
assert_has "the auth failure issue reports the key shape" \
    "$(cat "${RB}")" 'key file shape: ${keyshape.stdout}'

# =============================================================================
# The key-shape probe is pure shell, so unlike the rest of the runbook it can be
# exercised for real. Extracted from runbook.robot rather than copied, so the
# thing under test is the string that actually ships -- a copy would drift and
# then assert about itself.
printf '\n%s== Scenario L -- key shape probe (behavioural)%s\n' "${BLUE}" "${NC}"
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
# ".p12 keys" error as a missing one, which is what made the live failure
# ambiguous in the first place.
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

# The substrate environments are named from APIGEE_SUBSTRATE_SUFFIX, this
# bundle's own fixtures from the per-run suffix. They are usually equal and are
# not the same thing, so anything asserting on a substrate name must use the
# substrate suffix -- otherwise the moment the two diverge the assertion looks
# for an environment nobody created.
LIVE_V="$(cat "${BUNDLE}/.test/test-live.sh")"
# shellcheck disable=SC2016  # the needles are literal source text, not expansions
assert_has "test-live resolves the substrate suffix separately" \
    "${LIVE_V}" 'SUBSTRATE_SUFFIX="${APIGEE_SUBSTRATE_SUFFIX:-'
# shellcheck disable=SC2016
assert_has "  ...and names the substrate environment from it" \
    "${LIVE_V}" 'apigee-env-unattached-${SUBSTRATE_SUFFIX}'
# shellcheck disable=SC2016
assert_hasnt "  ...not from the per-run fixture suffix" \
    "${LIVE_V}" 'apigee-env-unattached-${SUFFIX}'


# --- the offline tier must be hermetic ---------------------------------------
# It reported different results on different machines until this landed: anyone
# who had sourced load-credentials.sh (which exports TF_VAR_org_id) carried a
# real org into a tier that is supposed to see only fixtures.
SELF_V="$(cat "${HERE}/run.sh")"   # not "$0": the cwd has moved by now
assert_has "the offline tier unsets the caller's credentials" \
    "${SELF_V}" "unset APIGEE_ORG GCP_PROJECT_ID"
assert_has "  ...including the TF_VAR_ spellings load-credentials.sh exports" \
    "${SELF_V}" "TF_VAR_org_id TF_VAR_project_id"


# --- the second runtime instance is OPT-IN -----------------------------------
# An EVALUATION organization permits exactly one runtime instance. This resource
# carried no count, so `terraform apply` failed on it every time -- which is why
# this configuration had never completed end to end on an eval org. It is kept
# as a multi-region failover fixture for a PAID organization, gated off by
# default. Drop the gate and every build-infra on an eval org breaks again.
#
# Comments stripped: the block explaining the cap quotes the very strings being
# asserted on.
TF_MAIN_V="$(grep -v "^[[:space:]]*#" "${BUNDLE}/.test/terraform/main.tf")"
TF_VARS_V="$(grep -v "^[[:space:]]*#" "${BUNDLE}/.test/terraform/variables.tf")"
assert_has "the second runtime instance is gated" \
    "${TF_MAIN_V}" "count = var.enable_secondary_instance ? 1 : 0"
assert_has "  ...and so is its attachment" \
    "${TF_MAIN_V}" "instance_id = google_apigee_instance.secondary[0].id"
assert_has "  ...on a variable that defaults to off" "${TF_VARS_V}" "enable_secondary_instance"
assert_eq  "  ...and the default really is false" \
    "$(awk '/variable "enable_secondary_instance"/{f=1} f&&/default/{print $3; exit}' \
        "${BUNDLE}/.test/terraform/variables.tf")" "false"
# The primary instance and both environments are substrate now, so this state
# must not try to create them -- five bundles share two environment slots.
assert_hasnt "this state no longer owns the primary instance" \
    "${TF_MAIN_V}" 'resource "google_apigee_instance" "primary"'
assert_hasnt "  ...nor either substrate environment" \
    "${TF_MAIN_V}" 'resource "google_apigee_environment"'

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
