#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-offline-tests.sh -- the offline tier for gcp-apigee-product-governance.
#
# Runs every check script against recorded Apigee management API responses with
# stubbed curl/gcloud. Needs NO credentials, NO cloud resources and NO network,
# so it can gate every PR.
#
# Each check is exercised twice:
#   known-positive : a fixture broken in a known way; the test FAILS if the
#                    check does not report it.
#   known-negative : a healthy fixture; the test FAILS if the check reports
#                    anything at all.
# Plus the "cannot run" tier: with every API call denied, no dimension may look
# healthy.
#
# FIXTURE PROVENANCE
# ------------------
# Field names, types and semantics below are taken from the Apigee v1 API
# discovery document (https://apigee.googleapis.com/$discovery/rest?version=v1),
# NOT from what the check scripts happen to expect. Specifically:
#   - ListApiProductsResponse wraps products under "apiProduct"
#   - ListAppsResponse wraps apps under "app" and paginates via nextPageToken
#   - ListOfDevelopersResponse wraps developers under "developer"
#   - Credential.expiresAt is an int64 *string* of epoch MILLISECONDS
#   - keyExpiresIn documents -1 as "the API key never expires"; a fixture
#     reproduces that trap because treating -1 as a past timestamp reports every
#     non-expiring key as expired
#   - ApiProductRef names the product in the lowercase field "apiproduct"
#   - developers.list returns email addresses only unless expand=true
#   - OrganizationProjectMapping carries the bare org name plus projectId
#
# Usage:  ./run-offline-tests.sh          (artifacts removed on success)
#         KEEP_ARTIFACTS=1 ./run-offline-tests.sh
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$HERE/../.." && pwd)"
ARTIFACTS="$(mktemp -d "${TMPDIR:-/tmp}/apigee-offline-XXXXXX")"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

FAILURES=0
CHECKS=0
CURRENT_CASE=""

pass() { CHECKS=$((CHECKS + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
fail() {
  CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1))
  printf '    \033[31m✗ %s\033[0m\n' "$1"
  [ -n "${2:-}" ] && printf '        expected: %s\n' "$2"
  [ -n "${3:-}" ] && printf '        actual:   %s\n' "$3"
  printf '        case:     %s\n' "$CURRENT_CASE"
  return 0
}

# ---------------------------------------------------------------------------
# Fixture builders. Timestamps are computed relative to now so the expiry
# fixtures stay meaningful whenever the suite runs.
# ---------------------------------------------------------------------------
NOW_S="$(date -u +%s)"
MS_EXPIRED="$(( (NOW_S - 5 * 86400) * 1000 ))"     # 5 days in the past
MS_SOON="$(( (NOW_S + 10 * 86400) * 1000 ))"       # inside a 30-day window
MS_FAR="$(( (NOW_S + 900 * 86400) * 1000 ))"       # far outside it

write_orgs_fixture() {
  # Two organizations are visible; only one is bound to the project under test.
  # organizations.list has no project filter, so picking the first entry blindly
  # would audit someone else's organization.
  cat > "$1/organizations" <<'EOF'
{"organizations":[
  {"organization":"other-org","projectId":"some-other-project","location":"us-west1"},
  {"organization":"testorg","projectId":"proj-under-test","location":"us-west1"}
]}
EOF
}

write_broken_fixtures() {
  local d="$1"; mkdir -p "$d"; write_orgs_fixture "$d"
  cat > "$d/organizations_testorg_apiproducts" <<'EOF'
{"apiProduct":[
  {"name":"auto-prod","displayName":"Auto Approve API","approvalType":"auto","quota":"100","quotaInterval":"1","quotaTimeUnit":"minute"},
  {"name":"noquota-prod","displayName":"No Quota API","approvalType":"manual"},
  {"name":"orphan-prod","displayName":"Orphaned API","approvalType":"manual","quota":"50","quotaInterval":"1","quotaTimeUnit":"minute"}
]}
EOF
  cat > "$d/organizations_testorg_apps" <<EOF
{"app":[
  {"name":"expired-app","appId":"a1","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYEXPIRED0001","status":"approved","expiresAt":"$MS_EXPIRED",
     "apiProducts":[{"apiproduct":"auto-prod","status":"approved"}]}]},
  {"name":"expiring-app","appId":"a2","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYSOON000002","status":"approved","expiresAt":"$MS_SOON",
     "apiProducts":[{"apiproduct":"noquota-prod","status":"approved"}]}]},
  {"name":"never-expires-app","appId":"a3","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYNEVER00003","status":"approved","expiresAt":"-1",
     "apiProducts":[{"apiproduct":"auto-prod","status":"approved"}]}]},
  {"name":"zero-expiry-app","appId":"a6","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYZERO000006","status":"approved","expiresAt":"0",
     "apiProducts":[{"apiproduct":"auto-prod","status":"approved"}]}]},
  {"name":"empty-app","appId":"a4","developerId":"dev1","status":"approved","credentials":[]},
  {"name":"dangling-app","appId":"a5","developerId":"dev2","status":"approved",
   "credentials":[{"consumerKey":"KEYDANGLE0004","status":"approved","expiresAt":"-1",
     "apiProducts":[{"apiproduct":"ghost-prod","status":"approved"}]}]}
]}
EOF
  cat > "$d/organizations_testorg_developers" <<'EOF'
{"developer":[
  {"developerId":"dev1","email":"active@example.com","userName":"active","status":"active"},
  {"developerId":"dev2","email":"blocked@example.com","userName":"blocked","status":"inactive"}
]}
EOF
  echo '{"environment":["test"]}' > "$d/organizations_testorg_environments"
}

write_healthy_fixtures() {
  local d="$1"; mkdir -p "$d"; write_orgs_fixture "$d"
  cat > "$d/organizations_testorg_apiproducts" <<'EOF'
{"apiProduct":[
  {"name":"good-prod","displayName":"Good API","approvalType":"manual","quota":"1000","quotaInterval":"1","quotaTimeUnit":"minute"}
]}
EOF
  cat > "$d/organizations_testorg_apps" <<EOF
{"app":[
  {"name":"good-app","appId":"b1","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYGOOD000001","status":"approved","expiresAt":"$MS_FAR",
     "apiProducts":[{"apiproduct":"good-prod","status":"approved"}]}]}
]}
EOF
  cat > "$d/organizations_testorg_developers" <<'EOF'
{"developer":[{"developerId":"dev1","email":"active@example.com","userName":"active","status":"active"}]}
EOF
  # An environment plus matching analytics traffic for good-app, so the usage
  # cross-reference genuinely runs and finds nothing wrong. Without this the
  # healthy case could pass merely because the analytics step was skipped.
  echo '{"environment":["test"]}' > "$d/organizations_testorg_environments"
  cat > "$d/organizations_testorg_environments_test_stats_developer_app" <<'EOF'
{"environments":[{"name":"test","dimensions":[{"name":"good-app","metrics":[{"name":"sum(message_count)","values":["42"]}]}]}]}
EOF
}

write_noref_fixtures() {
  # Products exist but no app references any of them: the maximal-orphan case.
  local d="$1"; mkdir -p "$d"; write_orgs_fixture "$d"
  cp "$ARTIFACTS/fixtures-broken/organizations_testorg_apiproducts" "$d/"
  cp "$ARTIFACTS/fixtures-broken/organizations_testorg_developers" "$d/"
  echo '{"environment":["test"]}' > "$d/organizations_testorg_environments"
  cat > "$d/organizations_testorg_apps" <<'EOF'
{"app":[{"name":"lonely-app","appId":"c1","developerId":"dev1","status":"approved",
  "credentials":[{"consumerKey":"KEYLONELY0001","status":"approved","expiresAt":"-1","apiProducts":[]}]}]}
EOF
}

write_quoted_fixtures() {
  # Apigee display names may contain double quotes and backslashes. Building
  # issue JSON by string interpolation corrupts the output for these.
  local d="$1"; mkdir -p "$d"; write_orgs_fixture "$d"
  jq -n '{apiProduct:[{name:"quoted-prod",displayName:"Pay \"as you go\" API \\ tier",approvalType:"auto",quota:"10",quotaInterval:"1",quotaTimeUnit:"minute"}]}' \
    > "$d/organizations_testorg_apiproducts"
  echo '{"app":[]}' > "$d/organizations_testorg_apps"
  echo '{"developer":[]}' > "$d/organizations_testorg_developers"
  echo '{"environment":[]}' > "$d/organizations_testorg_environments"
}

write_paging_fixtures() {
  # apps.list paginates with rows/startKey -- NOT pageSize/pageToken, which the
  # real API rejects alongside expand/includeCred/status. startKey is the app ID
  # and is inclusive, so the cursor record repeats as the first element of the
  # next page. Run with APIGEE_PAGE_SIZE=2:
  #   page 1 (no cursor)   -> a1, a2   (2 == page size, so keep going)
  #   page 2 (startKey=a2) -> a2, a3   (a2 dropped as the repeat)
  #   page 3 (startKey=a3) -> a3       (1 < page size, stop)
  local d="$1"; mkdir -p "$d"; write_orgs_fixture "$d"
  cat > "$d/organizations_testorg_apiproducts" <<'EOF'
{"apiProduct":[{"name":"page2-prod","displayName":"Referenced only from the last page","approvalType":"manual","quota":"10","quotaInterval":"1","quotaTimeUnit":"minute"}]}
EOF
  cat > "$d/organizations_testorg_apps" <<'EOF'
{"app":[
  {"name":"page1-app","appId":"a1","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYPAGE1","status":"approved","expiresAt":"-1","apiProducts":[]}]},
  {"name":"page1b-app","appId":"a2","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYPAGE1B","status":"approved","expiresAt":"-1","apiProducts":[]}]}
]}
EOF
  cat > "$d/organizations_testorg_apps__page_a2" <<'EOF'
{"app":[
  {"name":"page1b-app","appId":"a2","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYPAGE1B","status":"approved","expiresAt":"-1","apiProducts":[]}]},
  {"name":"page2-app","appId":"a3","developerId":"dev1","status":"approved",
   "credentials":[{"consumerKey":"KEYPAGE2","status":"approved","expiresAt":"-1",
     "apiProducts":[{"apiproduct":"page2-prod","status":"approved"}]}]}
]}
EOF
  # Final page: the cursor record only, so the loop terminates.
  cat > "$d/organizations_testorg_apps__page_a3" <<'EOF'
{"app":[{"name":"page2-app","appId":"a3","developerId":"dev1","status":"approved",
  "credentials":[{"consumerKey":"KEYPAGE2","status":"approved","expiresAt":"-1",
    "apiProducts":[{"apiproduct":"page2-prod","status":"approved"}]}]}]}
EOF
  cat > "$d/organizations_testorg_developers" <<'EOF'
{"developer":[{"developerId":"dev1","email":"active@example.com","userName":"active","status":"active"}]}
EOF
  echo '{"environment":[]}' > "$d/organizations_testorg_environments"
}

# ---------------------------------------------------------------------------
# Test harness plumbing
# ---------------------------------------------------------------------------
run_check() {
  # run_check <case-dir> <fixture-dir> <script> [extra env assignments...]
  local case_dir="$1" fixture_dir="$2" script="$3"; shift 3
  mkdir -p "$case_dir"
  (
    cd "$case_dir" || exit 1
    export PATH="$HERE/stubs:$PATH"
    export APIDIR="$fixture_dir"
    export URLLOG="$case_dir/requested-urls.txt"
    # Per-case overrides must be applied BEFORE the defaults below, or a case
    # that clears APIGEE_ORG to exercise org resolution silently keeps the
    # default and tests nothing.
    for assignment in "$@"; do export "${assignment?}"; done
    export GCP_PROJECT_ID="${GCP_PROJECT_ID_OVERRIDE:-proj-under-test}"
    export APIGEE_ORG="${APIGEE_ORG_OVERRIDE-testorg}"
    bash "$BUNDLE_DIR/$script" > stdout.txt 2> stderr.txt
    echo "$?" > exit_code.txt
  )
}

types_in() { jq -r '[.[].issue_type] | sort | join(",")' "$1" 2>/dev/null || echo "<unreadable>"; }

assert_exit_zero() {
  local case_dir="$1" label="$2" code
  code="$(cat "$case_dir/exit_code.txt" 2>/dev/null || echo "missing")"
  if [ "$code" = "0" ]; then pass "$label exits 0"
  else fail "$label exits 0" "0" "$code (stderr: $(head -c 200 "$case_dir/stderr.txt" 2>/dev/null))"; fi
}

assert_valid_array() {
  local file="$1" label="$2"
  if jq -e 'type == "array"' "$file" >/dev/null 2>&1; then pass "$label is a JSON array"
  else fail "$label is a JSON array" "a parseable JSON array" "$(head -c 200 "$file" 2>/dev/null)"; fi
}

assert_has_type() {
  local file="$1" want="$2" label="$3"
  if jq -e --arg t "$want" 'any(.[]; .issue_type == $t)' "$file" >/dev/null 2>&1; then
    pass "$label reports '$want'"
  else
    fail "$label reports '$want'" "an issue with issue_type=$want" "issue types present: $(types_in "$file")"
  fi
}

assert_lacks_type() {
  local file="$1" unwanted="$2" label="$3"
  if jq -e --arg t "$unwanted" 'any(.[]; .issue_type == $t)' "$file" >/dev/null 2>&1; then
    fail "$label does NOT report '$unwanted'" "no issue with issue_type=$unwanted" "issue types present: $(types_in "$file")"
  else
    pass "$label does not report '$unwanted'"
  fi
}

assert_empty() {
  local file="$1" label="$2" n
  n="$(jq 'length' "$file" 2>/dev/null || echo "unreadable")"
  if [ "$n" = "0" ]; then pass "$label reports nothing"
  else fail "$label reports nothing" "0 issues" "$n issue(s): $(types_in "$file")"; fi
}

assert_count() {
  local file="$1" want="$2" label="$3" n
  n="$(jq 'length' "$file" 2>/dev/null || echo "unreadable")"
  if [ "$n" = "$want" ]; then pass "$label reports exactly $want issue(s)"
  else fail "$label reports exactly $want issue(s)" "$want" "$n ($(types_in "$file"))"; fi
}

assert_access() {
  local file="$1" want="$2" label="$3" got
  got="$(jq -r '.access_ok' "$file" 2>/dev/null || echo "missing")"
  if [ "$got" = "$want" ]; then pass "$label reports access_ok=$want"
  else fail "$label reports access_ok=$want" "$want" "$got"; fi
}

assert_applicable() {
  # <file> <expected true|false> <label>
  #
  # Read with has() rather than `.applicable // "absent"`. jq's // falls through
  # on `false` as well as null, so a wrongly-set false would read as "absent"
  # and this assertion would pass under the exact mutation it exists to catch.
  local file="$1" want="$2" label="$3" got
  got="$(jq -r 'if has("applicable") then (.applicable | tostring) else "absent" end' "$file" 2>/dev/null || echo "unreadable")"
  if [ "$got" = "$want" ]; then pass "$label reports applicable=$want"
  else fail "$label reports applicable=$want" "$want" "$got"; fi
}

assert_url_matches() {
  local case_dir="$1" pattern="$2" label="$3"
  if grep -q -- "$pattern" "$case_dir/requested-urls.txt" 2>/dev/null; then
    pass "$label requests '$pattern'"
  else
    fail "$label requests '$pattern'" "a request containing $pattern" "$(sed 's|https://apigee.googleapis.com/v1/||' "$case_dir/requested-urls.txt" 2>/dev/null | sort -u | tr '\n' ' ')"
  fi
}

section() { CURRENT_CASE="$1"; printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
echo "Offline suite for gcp-apigee-product-governance"
echo "Artifacts: $ARTIFACTS"

write_broken_fixtures  "$ARTIFACTS/fixtures-broken"
write_healthy_fixtures "$ARTIFACTS/fixtures-healthy"
write_noref_fixtures   "$ARTIFACTS/fixtures-noref"
write_quoted_fixtures  "$ARTIFACTS/fixtures-quoted"
write_paging_fixtures  "$ARTIFACTS/fixtures-paging"

# --- KNOWN-POSITIVE: every check must report its planted defect --------------
section "known-positive: broken organization"

run_check "$ARTIFACTS/pos-products" "$ARTIFACTS/fixtures-broken" check_api_products.sh
assert_exit_zero "$ARTIFACTS/pos-products" "check_api_products"
assert_valid_array "$ARTIFACTS/pos-products/api_products_issues.json" "api_products_issues.json"
assert_access "$ARTIFACTS/pos-products/api_products_status.json" "true" "check_api_products"
assert_has_type "$ARTIFACTS/pos-products/api_products_issues.json" "auto_approval" "check_api_products"
assert_has_type "$ARTIFACTS/pos-products/api_products_issues.json" "missing_quota" "check_api_products"

run_check "$ARTIFACTS/pos-creds" "$ARTIFACTS/fixtures-broken" check_app_credentials.sh
assert_exit_zero "$ARTIFACTS/pos-creds" "check_app_credentials"
assert_has_type "$ARTIFACTS/pos-creds/api_credentials_issues.json" "credential_expired" "check_app_credentials"
assert_has_type "$ARTIFACTS/pos-creds/api_credentials_issues.json" "credential_expiring" "check_app_credentials"
# The trap: expiresAt -1 and 0 both mean "never expires". Two apps use them, so
# a regression that treats them as past timestamps shows up as extra findings.
assert_count "$ARTIFACTS/pos-creds/api_credentials_issues.json" 2 "check_app_credentials"
# Assert on OCCURRENCES, not just issue count. Aggregation folds every affected
# credential into one issue per class, so a regression that wrongly flags the
# never-expiring keys (expiresAt -1 and 0) would leave the issue count at 2
# while inflating affected_count from 1 to 4. The count alone no longer detects
# the -1 trap; this does.
exp_aff="$(jq -r '.[] | select(.issue_type=="credential_expired") | .affected_count' "$ARTIFACTS/pos-creds/api_credentials_issues.json" 2>/dev/null)"
if [ "$exp_aff" = "1" ]; then
  pass "only the genuinely expired key is counted (expiresAt -1 and 0 excluded)"
else
  fail "only the genuinely expired key is counted (expiresAt -1 and 0 excluded)" \
       "affected_count=1 on the expired issue" \
       "affected_count=$exp_aff -- non-expiring keys are being counted as expired"
fi
# The title must name the configured warning WINDOW, which is stable, rather
# than the live countdown, which changes daily. See the issue-hygiene section.
# The window (KEY_EXPIRY_WARNING_DAYS) is a configured threshold, so it is
# stable across runs -- unlike an occurrence count or a countdown.
if jq -e 'any(.[]; .issue_type == "credential_expiring" and (.title | test("expires? within [0-9]+ days")))' \
     "$ARTIFACTS/pos-creds/api_credentials_issues.json" >/dev/null 2>&1; then
  pass "check_app_credentials names the stable warning window in the expiring title"
else
  fail "check_app_credentials names the stable warning window in the expiring title" \
       "title matching 'expire(s) within <N> days'" \
       "$(jq -r '.[] | select(.issue_type=="credential_expiring") | .title' "$ARTIFACTS/pos-creds/api_credentials_issues.json" 2>/dev/null)"
fi
if jq -e 'all(.[]; (.apps | type == "array") and ((.apps | length) > 0) and ((.affected_count | type) == "number"))' "$ARTIFACTS/pos-creds/api_credentials_issues.json" >/dev/null 2>&1; then
  pass "check_app_credentials lists affected apps and a count on every issue"
else
  fail "check_app_credentials lists affected apps and a count on every issue" \
       "non-empty .apps array and numeric .affected_count on all issues" \
       "$(jq -c '[.[] | {issue_type, apps, affected_count}]' "$ARTIFACTS/pos-creds/api_credentials_issues.json" 2>/dev/null)"
fi

run_check "$ARTIFACTS/pos-orphan" "$ARTIFACTS/fixtures-broken" check_orphaned_entitlements.sh
assert_exit_zero "$ARTIFACTS/pos-orphan" "check_orphaned_entitlements"
assert_has_type "$ARTIFACTS/pos-orphan/orphaned_entitlements_issues.json" "app_no_keys" "check_orphaned_entitlements"
assert_has_type "$ARTIFACTS/pos-orphan/orphaned_entitlements_issues.json" "orphaned_product" "check_orphaned_entitlements"

run_check "$ARTIFACTS/pos-dev" "$ARTIFACTS/fixtures-broken" check_developer_status.sh
assert_exit_zero "$ARTIFACTS/pos-dev" "check_developer_status"
assert_has_type "$ARTIFACTS/pos-dev/developer_status_issues.json" "dangling_product_ref" "check_developer_status"
assert_has_type "$ARTIFACTS/pos-dev/developer_status_issues.json" "developer_status_drift" "check_developer_status"
# Without expand=true the developers endpoint returns email addresses only, and
# the status half of this check silently matches nothing.
assert_url_matches "$ARTIFACTS/pos-dev" "developers?expand=true" "check_developer_status"
assert_url_matches "$ARTIFACTS/pos-dev" "includeCred=true" "check_developer_status"

run_check "$ARTIFACTS/pos-discover" "$ARTIFACTS/fixtures-broken" discover_entitlements.sh
assert_exit_zero "$ARTIFACTS/pos-discover" "discover_entitlements"
assert_empty "$ARTIFACTS/pos-discover/entitlements_discovery_issues.json" "discover_entitlements (readable org)"
assert_access "$ARTIFACTS/pos-discover/entitlements_discovery_status.json" "true" "discover_entitlements"
if [ "$(jq -r '.app_count' "$ARTIFACTS/pos-discover/entitlements_discovery.json" 2>/dev/null)" = "6" ]; then
  pass "discover_entitlements snapshots all 6 apps"
else
  fail "discover_entitlements snapshots all 6 apps" "6" "$(jq -r '.app_count' "$ARTIFACTS/pos-discover/entitlements_discovery.json" 2>/dev/null)"
fi

# --- KNOWN-NEGATIVE: a healthy organization must produce nothing -------------
section "known-negative: healthy organization"

run_check "$ARTIFACTS/neg-products" "$ARTIFACTS/fixtures-healthy" check_api_products.sh
assert_exit_zero "$ARTIFACTS/neg-products" "check_api_products"
assert_access "$ARTIFACTS/neg-products/api_products_status.json" "true" "check_api_products"
assert_empty "$ARTIFACTS/neg-products/api_products_issues.json" "check_api_products (healthy)"

run_check "$ARTIFACTS/neg-creds" "$ARTIFACTS/fixtures-healthy" check_app_credentials.sh
assert_exit_zero "$ARTIFACTS/neg-creds" "check_app_credentials"
assert_empty "$ARTIFACTS/neg-creds/api_credentials_issues.json" "check_app_credentials (healthy)"

run_check "$ARTIFACTS/neg-orphan" "$ARTIFACTS/fixtures-healthy" check_orphaned_entitlements.sh
assert_exit_zero "$ARTIFACTS/neg-orphan" "check_orphaned_entitlements"
assert_empty "$ARTIFACTS/neg-orphan/orphaned_entitlements_issues.json" "check_orphaned_entitlements (healthy)"

run_check "$ARTIFACTS/neg-dev" "$ARTIFACTS/fixtures-healthy" check_developer_status.sh
assert_exit_zero "$ARTIFACTS/neg-dev" "check_developer_status"
assert_empty "$ARTIFACTS/neg-dev/developer_status_issues.json" "check_developer_status (healthy)"

# --- CANNOT RUN: no dimension may look healthy -------------------------------
section "cannot run: every API call denied"

for spec in "check_api_products.sh:api_products_status.json:api_products_issues.json" \
            "check_app_credentials.sh:api_credentials_status.json:api_credentials_issues.json" \
            "check_orphaned_entitlements.sh:orphaned_entitlements_status.json:orphaned_entitlements_issues.json" \
            "check_developer_status.sh:developer_status_status.json:developer_status_issues.json"; do
  script="${spec%%:*}"; rest="${spec#*:}"; status_file="${rest%%:*}"; issues_file="${rest##*:}"
  dir="$ARTIFACTS/fail-${script%.sh}"
  run_check "$dir" "$ARTIFACTS/fixtures-broken" "$script" "API_FAIL=1"
  assert_exit_zero "$dir" "$script (denied)"
  assert_valid_array "$dir/$issues_file" "$issues_file (denied)"
  # This is the whole point of the tier: access_ok=false is what makes the SLI
  # score the dimension 0 instead of reading "no issues" as perfect health.
  assert_access "$dir/$status_file" "false" "$script (denied)"
done

section "cannot run: discovery reports the failure as an issue"
run_check "$ARTIFACTS/fail-discover" "$ARTIFACTS/fixtures-broken" discover_entitlements.sh "API_FAIL=1"
assert_exit_zero "$ARTIFACTS/fail-discover" "discover_entitlements (denied)"
assert_access "$ARTIFACTS/fail-discover/entitlements_discovery_status.json" "false" "discover_entitlements (denied)"
assert_has_type "$ARTIFACTS/fail-discover/entitlements_discovery_issues.json" "discovery_access_error" "discover_entitlements (denied)"
for f in entitlements_discovery_issues.json entitlements_discovery_status.json entitlements_discovery.json; do
  if [ -f "$ARTIFACTS/fail-discover/$f" ]; then pass "discover_entitlements still writes $f when denied"
  else fail "discover_entitlements still writes $f when denied" "$f present" "missing"; fi
done

# --- Regression cases --------------------------------------------------------
section "regression: no app references any product (maximal orphan)"
run_check "$ARTIFACTS/reg-noref" "$ARTIFACTS/fixtures-noref" check_orphaned_entitlements.sh
assert_exit_zero "$ARTIFACTS/reg-noref" "check_orphaned_entitlements"
assert_has_type "$ARTIFACTS/reg-noref/orphaned_entitlements_issues.json" "orphaned_product" "check_orphaned_entitlements (no references)"
# ONE issue listing all three, not three issues -- see the aggregation section.
n_orphan_issues="$(jq '[.[] | select(.issue_type == "orphaned_product")] | length' "$ARTIFACTS/reg-noref/orphaned_entitlements_issues.json" 2>/dev/null || echo 0)"
n_orphans="$(jq -r '[.[] | select(.issue_type == "orphaned_product") | .affected_count] | add // 0' "$ARTIFACTS/reg-noref/orphaned_entitlements_issues.json" 2>/dev/null || echo 0)"
if [ "$n_orphan_issues" = "1" ] && [ "$n_orphans" = "3" ]; then
  pass "all 3 unreferenced products are reported in a single issue"
else
  fail "all 3 unreferenced products are reported in a single issue" \
       "1 issue with affected_count=3" "$n_orphan_issues issue(s), affected_count=$n_orphans"
fi

section "regression: names containing quotes and backslashes"
run_check "$ARTIFACTS/reg-quoted" "$ARTIFACTS/fixtures-quoted" check_api_products.sh
assert_exit_zero "$ARTIFACTS/reg-quoted" "check_api_products"
assert_valid_array "$ARTIFACTS/reg-quoted/api_products_issues.json" "api_products_issues.json (quoted names)"
assert_has_type "$ARTIFACTS/reg-quoted/api_products_issues.json" "auto_approval" "check_api_products (quoted names)"
if jq -e '.[0].details | contains("Pay \"as you go\" API \\ tier")' "$ARTIFACTS/reg-quoted/api_products_issues.json" >/dev/null 2>&1; then
  pass "the display name survives verbatim into the issue details"
else
  fail "the display name survives verbatim into the issue details" \
       'details containing: Pay "as you go" API \ tier' \
       "$(jq -r '.[0].details // "<none>"' "$ARTIFACTS/reg-quoted/api_products_issues.json" 2>/dev/null | head -c 160)"
fi

section "regression: paginated app list uses rows/startKey, not pageSize"
run_check "$ARTIFACTS/reg-paging" "$ARTIFACTS/fixtures-paging" check_orphaned_entitlements.sh "APIGEE_PAGE_SIZE=2"
assert_exit_zero "$ARTIFACTS/reg-paging" "check_orphaned_entitlements"
assert_url_matches "$ARTIFACTS/reg-paging" "rows=2" "check_orphaned_entitlements"
assert_url_matches "$ARTIFACTS/reg-paging" "startKey=a2" "check_orphaned_entitlements"
# page2-prod is referenced only by an app on the last page. Stopping early would
# report it as orphaned, so its absence proves every page was consumed.
assert_lacks_type "$ARTIFACTS/reg-paging/orphaned_entitlements_issues.json" "orphaned_product" "check_orphaned_entitlements (paged)"
# The cursor record repeats on each page; it must not be counted twice.
if grep -q "pageSize=" "$ARTIFACTS/reg-paging/requested-urls.txt" 2>/dev/null; then
  fail "the app listing never sends pageSize" "no pageSize parameter" \
       "$(sed 's|https://apigee.googleapis.com/v1/||' "$ARTIFACTS/reg-paging/requested-urls.txt" | grep pageSize | head -1)"
else
  pass "the app listing never sends pageSize"
fi

section "regression: a startKey that never advances must not hang"
mkdir -p "$ARTIFACTS/fixtures-loop"
cp "$ARTIFACTS/fixtures-paging"/* "$ARTIFACTS/fixtures-loop"/ 2>/dev/null
# The page for startKey=a2 hands back a2 as its own last record, so the cursor
# cannot advance.
cat > "$ARTIFACTS/fixtures-loop/organizations_testorg_apps__page_a2" <<'EOF'
{"app":[
  {"name":"page1b-app","appId":"a2","developerId":"dev1","status":"approved","credentials":[]},
  {"name":"page1b-app","appId":"a2","developerId":"dev1","status":"approved","credentials":[]}
]}
EOF
run_check "$ARTIFACTS/reg-loop" "$ARTIFACTS/fixtures-loop" check_orphaned_entitlements.sh "APIGEE_PAGE_SIZE=2"
assert_exit_zero "$ARTIFACTS/reg-loop" "check_orphaned_entitlements (looping cursor)"
assert_access "$ARTIFACTS/reg-loop/orphaned_entitlements_status.json" "false" "check_orphaned_entitlements (looping cursor)"

section "org gate: a project with no Apigee organization is an ERROR, not a state"
# The generation rule gates on gcp_apigee_organizations, so an SLX exists only
# where an org is indexed and "this project has no Apigee" cannot arise. The
# case is DELETED rather than handled: reaching it means the bundle was pointed
# at the wrong project by direct invocation, which is a failure to report.
mkdir -p "$ARTIFACTS/fixtures-noapigee"
cat > "$ARTIFACTS/fixtures-noapigee/organizations" <<'EOF'
{"organizations":[{"organization":"someone-elses-org","projectId":"unrelated-project","location":"us-west1"}]}
EOF
run_check "$ARTIFACTS/na-products" "$ARTIFACTS/fixtures-noapigee" check_api_products.sh "APIGEE_ORG_OVERRIDE="
assert_exit_zero "$ARTIFACTS/na-products" "check_api_products (project has no org)"
assert_access "$ARTIFACTS/na-products/api_products_status.json" "false" "check_api_products (project has no org)"
if grep -q 'has no Apigee organization' "$ARTIFACTS/na-products/api_products_status.json" 2>/dev/null; then
  pass "the reason says the project has no Apigee organization"
else
  fail "the reason says the project has no Apigee organization" "a reason naming the absent org" \
       "$(jq -r '.reason' "$ARTIFACTS/na-products/api_products_status.json" 2>/dev/null)"
fi
# The status sidecar no longer carries an applicable field at all.
for f in "$ARTIFACTS"/*/*_status.json; do
  [ -f "$f" ] || continue
  if jq -e 'has("applicable")' "$f" >/dev/null 2>&1; then
    fail "no status sidecar carries an applicable field" "no applicable key" "$(basename "$(dirname "$f")")/$(basename "$f")"
    break
  fi
done
jq -e 'has("applicable")' "$ARTIFACTS"/*/*_status.json >/dev/null 2>&1 || \
  pass "no status sidecar carries an applicable field"
# And the not-applicable machinery is gone from the library.
for sym in apigee_finish_not_applicable APIGEE_APPLICABLE apigee_body_says_api_disabled; do
  if grep -q "$sym" "$BUNDLE_DIR/apigee_common.sh"; then
    fail "apigee_common.sh no longer defines $sym" "absent" "still present"
  else
    pass "apigee_common.sh no longer defines $sym"
  fi
done


section "shared-org contract: both spellings of the organization name"
# The sibling Apigee bundles name the same shared organization in the
# resource-name form (TF_VAR_org_id="organizations/<org>"). The API paths built
# here already carry that segment, so an un-normalised value produces
# organizations/organizations/<org>/... and 404s every call.
run_check "$ARTIFACTS/org-prefixed" "$ARTIFACTS/fixtures-broken" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=organizations/testorg"
assert_exit_zero "$ARTIFACTS/org-prefixed" "check_api_products (prefixed org)"
assert_access "$ARTIFACTS/org-prefixed/api_products_status.json" "true" "check_api_products (prefixed org)"
assert_has_type "$ARTIFACTS/org-prefixed/api_products_issues.json" "auto_approval" "check_api_products (prefixed org)"
if grep -q "organizations/organizations/" "$ARTIFACTS/org-prefixed/requested-urls.txt" 2>/dev/null; then
  fail "the organizations/ prefix is not doubled into the request path" \
       "organizations/testorg/apiproducts" \
       "$(sed 's|https://apigee.googleapis.com/v1/||' "$ARTIFACTS/org-prefixed/requested-urls.txt" | head -1)"
else
  pass "the organizations/ prefix is not doubled into the request path"
fi

# TF_VAR_org_id alone, with APIGEE_ORG unset, is the sibling harnesses' contract.
run_check "$ARTIFACTS/org-tfvar" "$ARTIFACTS/fixtures-broken" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=" "TF_VAR_org_id=organizations/testorg"
assert_exit_zero "$ARTIFACTS/org-tfvar" "check_api_products (TF_VAR_org_id)"
assert_access "$ARTIFACTS/org-tfvar/api_products_status.json" "true" "check_api_products (TF_VAR_org_id)"
assert_has_type "$ARTIFACTS/org-tfvar/api_products_issues.json" "auto_approval" "check_api_products (TF_VAR_org_id)"

section "runbook self-sufficiency: the access-failure signal has a consumer"
# The SLI used to be the only thing that read the access_ok sidecars; with it
# removed, the runbook must consume them itself. A check that cannot read the
# API writes an EMPTY issues array, so if nothing reads the sidecar a blind
# check is indistinguishable from a clean one -- the defect this bundle exists
# to prevent, re-entering through the side door.
RUNBOOK="$BUNDLE_DIR/runbook.robot"
for pair in "api_products_issues.json:api_products_status.json" \
            "api_credentials_issues.json:api_credentials_status.json" \
            "orphaned_entitlements_issues.json:orphaned_entitlements_status.json" \
            "developer_status_issues.json:developer_status_status.json"; do
  issues="${pair%%:*}"; status="${pair##*:}"
  if grep -q "Report Issues From File    $issues .*$status" "$RUNBOOK"; then
    pass "runbook passes $status alongside $issues"
  else
    fail "runbook passes $status alongside $issues" \
         "Report Issues From File ... $status" \
         "$(grep -o "Report Issues From File    $issues.*" "$RUNBOOK" | head -1)"
  fi
done
if grep -q 'Report Access Failure' "$RUNBOOK"; then
  pass "runbook defines a Report Access Failure keyword"
else
  fail "runbook defines a Report Access Failure keyword" "keyword present" "absent"
fi
# The sidecar every check writes on the denied path must be exactly what that
# keyword keys on, or the wiring above reports on a field that is never set.
if jq -e 'has("access_ok") and (.access_ok == false)' \
     "$ARTIFACTS/fail-check_api_products/api_products_status.json" >/dev/null 2>&1; then
  pass "a denied check writes access_ok=false for the runbook to key on"
else
  fail "a denied check writes access_ok=false for the runbook to key on" \
       "access_ok=false" \
       "$(jq -c . "$ARTIFACTS/fail-check_api_products/api_products_status.json" 2>/dev/null)"
fi
# ...and it pairs with an EMPTY issues array, which is precisely why the
# sidecar has to be read.
assert_empty "$ARTIFACTS/fail-check_api_products/api_products_issues.json" "a denied check (empty issues, hence the sidecar)"

section "secrets: nothing written to disk contains credential material"
# Redaction happens at fetch, so the secret never reaches a variable, a report
# or an artifact. Sweep EVERY file every case produced -- issues, sidecars, the
# discovery snapshot, and captured stdout/stderr -- not just issue fields.
mkdir -p "$ARTIFACTS/fixtures-secret"
cp "$ARTIFACTS/fixtures-broken"/* "$ARTIFACTS/fixtures-secret"/ 2>/dev/null
cat > "$ARTIFACTS/fixtures-secret/organizations_testorg_apps" <<'EOF'
{"app":[{"name":"secret-app","appId":"s1","developerId":"dev1","status":"approved",
  "attributes":[{"name":"stashed","value":"APPLEVELSECRET"}],
  "credentials":[{"consumerKey":"CONSUMERKEYLEAK","consumerSecret":"CONSUMERSECRETLEAK",
    "status":"approved","issuedAt":"1700000000000","expiresAt":"-1",
    "attributes":[{"name":"note","value":"CREDATTRSECRET"}],
    "apiProducts":[{"apiproduct":"auto-prod","status":"approved"}]}]}]}
EOF
for script in discover_entitlements.sh check_api_products.sh check_app_credentials.sh \
              check_orphaned_entitlements.sh check_developer_status.sh; do
  run_check "$ARTIFACTS/sec-${script%.sh}" "$ARTIFACTS/fixtures-secret" "$script"
done
secret_hits=0
for token in CONSUMERKEYLEAK CONSUMERSECRETLEAK CREDATTRSECRET APPLEVELSECRET \
             consumerKey consumerSecret; do
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    printf '        %s contains %s\n' "${hit#"$ARTIFACTS/"}" "$token"
    secret_hits=$((secret_hits + 1))
  done <<EOF
$(grep -rl -- "$token" "$ARTIFACTS"/sec-* 2>/dev/null || true)
EOF
done
if [ "$secret_hits" = "0" ]; then
  pass "no consumer key, secret or attribute value reaches any artifact"
else
  fail "no consumer key, secret or attribute value reaches any artifact" \
       "0 files containing credential material" "$secret_hits occurrence(s), listed above"
fi
# The redaction must not take the fields the checks depend on with it.
if jq -e '[.apps[].credentials[]? | select(has("expiresAt") and has("apiProducts"))] | length > 0' \
     "$ARTIFACTS/sec-discover_entitlements/entitlements_discovery.json" >/dev/null 2>&1; then
  pass "redaction keeps expiresAt and apiProducts, which the checks need"
else
  fail "redaction keeps expiresAt and apiProducts, which the checks need" \
       "credentials retaining expiresAt and apiProducts" \
       "$(jq -c '[.apps[].credentials[]? | keys] | flatten | unique' "$ARTIFACTS/sec-discover_entitlements/entitlements_discovery.json" 2>/dev/null)"
fi

section "STATIC: every surface is anchored on the organization"
# The SLX is generated FROM the org (the rule gates on gcp_apigee_organizations),
# so "... in project <x>" would label an org-level finding as a project-level
# one. APIGEE_ORG is a config_provided key supplied by the SLX at render time,
# which is what makes it usable in a task name -- the platform substitutes task
# names from config_provided, not from Robot suite variables.
#
# STATIC CHECK. Whether the platform resolves these cannot be proven here; it
# needs a discovery re-run and the stored resolved_tasks. Confirm after deploy.
for rf in runbook.robot sli.robot; do
  [ -f "$BUNDLE_DIR/$rf" ] || continue
  names="$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\* Keywords \*\*\*/{f=0} f && /^[A-Z]/' "$BUNDLE_DIR/$rf")"
  n_names="$(printf '%s' "$names" | grep -c .)"
  n_org="$(printf '%s' "$names" | grep -c 'APIGEE_ORG')"
  if [ "$n_names" = "$n_org" ]; then
    pass "$rf: all $n_names task name(s) name the org"
  else
    fail "$rf: all task names name the org" "$n_names" "$n_org"
  fi
  if printf '%s' "$names" | grep -q 'GCP_PROJECT_ID'; then
    fail "$rf: no task name still names the project" "none" \
         "$(printf '%s' "$names" | grep 'GCP_PROJECT_ID' | head -1)"
  else
    pass "$rf: no task name still names the project"
  fi
done
# The SLX supplies APIGEE_ORG, so the taskset template must actually provide it.
if grep -A1 'name: APIGEE_ORG' "$BUNDLE_DIR/.runwhen/templates/"*taskset.yaml 2>/dev/null | grep -q "{{apigee_org}}"; then
  pass "the taskset template supplies APIGEE_ORG from the resolved org"
else
  fail "the taskset template supplies APIGEE_ORG from the resolved org" "value: '{{apigee_org}}'" \
       "$(grep -A1 'name: APIGEE_ORG' "$BUNDLE_DIR/.runwhen/templates/"*taskset.yaml 2>/dev/null | tail -1)"
fi

section "STATIC: generation rule gates on the org and qualifies on resource"
GR="$BUNDLE_DIR/.runwhen/generation-rules/gcp-apigee-product-governance.yaml"
# Comments are stripped first. The rule's own commentary names the resource type
# and both qualifier spellings, so matching the whole file passes even with the
# gate reverted -- which is exactly how a reverted gate went unnoticed before.
GR_CODE="$(sed 's/#.*//' "$GR")"
for want in 'gcp_apigee_organizations' 'qualifiers: ["resource"]'; do
  if printf '%s' "$GR_CODE" | grep -qF "$want"; then
    pass "generation rule uses $want"
  else
    fail "generation rule uses $want" "$want" "absent from the rule's code"
  fi
done
for unwanted in '- project' 'qualifiers: ["project"]'; do
  if printf '%s' "$GR_CODE" | grep -qF "$unwanted"; then
    fail "generation rule does not use $unwanted" "absent" "still present"
  else
    pass "generation rule does not use $unwanted"
  fi
done

section "STATIC: templates resolve the org without raising"
for TPLF in "$BUNDLE_DIR/.runwhen/templates/"*-slx.yaml "$BUNDLE_DIR/.runwhen/templates/"*-taskset.yaml; do
  b="$(basename "$TPLF")"
  # Comments stripped for the same reason as the rule: the block explaining why
  # NOT to reach through match_resource.resource.name contains that very string.
  TPL_CODE="$(sed 's/#.*//' "$TPLF")"
  # Boolean mode: plain default() substitutes only for UNDEFINED, so a
  # workspaceInfo carrying apigee_org: "" would render APIGEE_ORG empty.
  for want in 'default(_res.name, true)' 'match_resource.resource | default({}, true)' \
              'default(qualifiers.resource, true)'; do
    if printf '%s' "$TPL_CODE" | grep -qF "$want"; then
      pass "$b uses $want"
    else
      fail "$b uses $want" "$want" "absent"
    fi
  done
  # Reaching through an absent .resource RAISES under jinja2.Undefined and
  # aborts the whole render rather than falling through.
  if printf '%s' "$TPL_CODE" | grep -qF 'default(match_resource.resource.name'; then
    fail "$b does not reach through match_resource.resource.name" "absent" "still present"
  else
    pass "$b does not reach through match_resource.resource.name"
  fi
done
if grep -qE '^ *value: organization' "$BUNDLE_DIR/.runwhen/templates/"*-slx.yaml; then
  pass "the SLX scope tag is the organization"
else
  fail "the SLX scope tag is the organization" "value: organization" \
       "$(grep -A1 'name: scope' "$BUNDLE_DIR/.runwhen/templates/"*-slx.yaml | tail -1)"
fi

section "STATIC: auth gates on the token, not on the activation"
RB="$BUNDLE_DIR/runbook.robot"
# shellcheck disable=SC2016  # matching Robot syntax literally; ${} must not expand
if grep -qF 'activate-service-account --key-file="./${gcp_credentials.key}" || true' "$RB"; then
  pass "service-account activation is tolerant (|| true)"
else
  fail "service-account activation is tolerant (|| true)" 'the call suffixed with || true' \
       "$(grep -o 'activate-service-account.*' "$RB" | head -1)"
fi
for want in 'TOKEN_ABSENT' 'print-access-token' 'KEY_NOT_JSON'; do
  if grep -qF "$want" "$RB"; then
    pass "the auth block references $want"
  else
    fail "the auth block references $want" "$want" "absent"
  fi
done
# The token probe is what aborts the suite; the activation must not.
if awk '/TOKEN_ABSENT/,/END/' "$RB" | grep -qE '^ *Fail '; then
  pass "the token probe fails the suite"
else
  fail "the token probe fails the suite" "a Fail inside the TOKEN_ABSENT branch" "absent"
fi

section "aggregation: issues are project-level, not per-resource"
# The SLX is generated per PROJECT, so an issue describes a project-level
# condition. Several apps hitting the same condition are occurrences of ONE
# issue, listed in details -- not one issue each.
mkdir -p "$ARTIFACTS/fixtures-many"
write_orgs_fixture "$ARTIFACTS/fixtures-many"
cat > "$ARTIFACTS/fixtures-many/organizations_testorg_apiproducts" <<'EOF'
{"apiProduct":[{"name":"real-prod","approvalType":"manual","quota":"10","quotaInterval":"1","quotaTimeUnit":"minute"}]}
EOF
cat > "$ARTIFACTS/fixtures-many/organizations_testorg_apps" <<'EOF'
{"app":[
 {"name":"app-a","appId":"1","developerId":"d1","status":"approved","credentials":[{"status":"approved","expiresAt":"-1","issuedAt":"1700000000000","apiProducts":[{"apiproduct":"ghost-1"}]}]},
 {"name":"app-b","appId":"2","developerId":"d1","status":"approved","credentials":[{"status":"approved","expiresAt":"-1","issuedAt":"1700000000000","apiProducts":[{"apiproduct":"ghost-2"}]}]},
 {"name":"app-c","appId":"3","developerId":"d1","status":"approved","credentials":[{"status":"approved","expiresAt":"-1","issuedAt":"1700000000000","apiProducts":[{"apiproduct":"ghost-1"}]}]}
]}
EOF
echo '{"developer":[{"developerId":"d1","email":"a@example.com","status":"active"}]}' > "$ARTIFACTS/fixtures-many/organizations_testorg_developers"
echo '{"environment":[]}' > "$ARTIFACTS/fixtures-many/organizations_testorg_environments"
run_check "$ARTIFACTS/agg-dangling" "$ARTIFACTS/fixtures-many" check_developer_status.sh
assert_exit_zero "$ARTIFACTS/agg-dangling" "check_developer_status (3 dangling apps)"
assert_count "$ARTIFACTS/agg-dangling/developer_status_issues.json" 1 "check_developer_status (3 dangling apps -> 1 issue)"
n_aff="$(jq -r '.[0].affected_count // 0' "$ARTIFACTS/agg-dangling/developer_status_issues.json" 2>/dev/null)"
if [ "$n_aff" = "3" ]; then pass "the single issue records all 3 occurrences"
else fail "the single issue records all 3 occurrences" "affected_count=3" "affected_count=$n_aff"; fi
if jq -e '.[0].apps | (type == "array") and (length == 3) and (index("app-a") != null) and (index("app-c") != null)' \
     "$ARTIFACTS/agg-dangling/developer_status_issues.json" >/dev/null 2>&1; then
  pass "the single issue lists every affected app"
else
  fail "the single issue lists every affected app" "apps array with app-a, app-b, app-c" \
       "$(jq -c '.[0].apps' "$ARTIFACTS/agg-dangling/developer_status_issues.json" 2>/dev/null)"
fi
# Each occurrence must be enumerated in details, since the title cannot name them.
det_hits=0
for app in app-a app-b app-c; do
  jq -e --arg a "$app" '.[0].details | contains($a)' "$ARTIFACTS/agg-dangling/developer_status_issues.json" >/dev/null 2>&1 \
    && det_hits=$((det_hits + 1))
done
if [ "$det_hits" = "3" ]; then pass "details enumerate every affected app"
else fail "details enumerate every affected app" "3 apps named in details" "$det_hits"; fi

# The title must carry NO resource identifier and NO count -- both change as the
# affected set changes, which would break deduplication just like a countdown.
# Checked against each issue's OWN affected-resource list rather than against
# guessed name patterns -- a hand-written regex silently stops matching when
# fixture names change, which is how a first version of this let a
# resource-named title through.
title_bad=0
for f in "$ARTIFACTS"/*/*_issues.json; do
  [ -f "$f" ] || continue
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    printf '        %s\n' "$t"
    title_bad=$((title_bad + 1))
  done <<EOF
$(jq -r '
    .[]
    | select((.affected_count // 0) > 0)
    | . as $i
    | (
        # (a) the title must not name any resource the issue is about.
        #     Bind the name to $res first: inside contains(.) the `.` would be
        #     the title itself, so the test would compare the title to itself
        #     and always match.
        ( ((($i.apps // []) + ($i.products // []) + ($i.developers // []))[]) as $res
          | select($i.title | contains($res))
          | "\($i.title)   <- names resource \($res)" ),
        # (b) nor state how many there are
        ( $i | select(.title | test("\\b\($i.affected_count)\\b"))
             | "\(.title)   <- carries occurrence count \($i.affected_count)" )
      )' "$f" 2>/dev/null || true)
EOF
done
if [ "$title_bad" = "0" ]; then
  pass "no aggregated title names a resource or carries an occurrence count"
else
  fail "no aggregated title names a resource or carries an occurrence count" \
       "titles free of resource names and counts" "$title_bad title(s), listed above"
fi

section "issue titles name the ORG scope, never the project"
# The SLX is generated FROM the organization, so an issue titled "... in project
# <x>" labels an org-level finding as a project-level one. Exactly one title may
# name the project: the one raised BECAUSE the org could not be determined, where
# the project is the only identifier that exists.
scope_bad=0
for f in "$ARTIFACTS"/pos-*/*_issues.json "$ARTIFACTS"/agg-*/*_issues.json; do
  [ -f "$f" ] || continue
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    printf '        %s\n' "$t"
    scope_bad=$((scope_bad + 1))
  done <<EOF
$(jq -r '.[] | .title
         | select(test("in project ") and (test("Cannot Determine Apigee Organization") | not))' "$f" 2>/dev/null || true)
EOF
done
if [ "$scope_bad" = "0" ]; then
  pass "no issue title names the project instead of the org"
else
  fail "no issue title names the project instead of the org" \
       "titles scoped 'in org \`<org>\`'" "$scope_bad title(s), listed above"
fi
# And they positively DO name the org.
org_named="$(jq -r '[.[] | .title | select(test("org `testorg`"))] | length' \
  "$ARTIFACTS/pos-products/api_products_issues.json" 2>/dev/null || echo 0)"
if [ "$org_named" -gt 0 ]; then
  pass "issue titles name the org scope"
else
  fail "issue titles name the org scope" "titles containing org \`testorg\`" \
       "$(jq -r '.[0].title // "none"' "$ARTIFACTS/pos-products/api_products_issues.json" 2>/dev/null)"
fi

section "issue hygiene: no credential material, and stable titles"
# 1. No consumer key or secret may reach any issue field.
#    For products using VerifyAPIKey the consumer key IS the credential, and
#    issue titles propagate furthest -- dashboards, notifications, chat.
#    The broken fixture's keys are known, so search for them directly.
cred_leak=0
for f in "$ARTIFACTS/pos-creds/api_credentials_issues.json" \
         "$ARTIFACTS/pos-dev/developer_status_issues.json"; do
  [ -f "$f" ] || continue
  for key in KEYEXPIRED0001 KEYSOON000002 KEYNEVER00003 KEYZERO000006 KEYDANGLE0004; do
    # Check the full key and prefixes down to 6 characters -- the original bug
    # leaked 8, so 6 catches it with margin. Not shorter: 4-character prefixes
    # of these fixture keys collide with ordinary English ("KEYS" matches
    # "Consumer keys should not be expired") and would fail spuriously.
    for len in 12 8 6; do
      frag="$(printf '%s' "$key" | cut -c1-$len)"
      if grep -qi -- "$frag" "$f"; then
        fail "no consumer key material in $(basename "$f")" \
             "no occurrence of any consumer key or prefix" \
             "found '$frag' in $(basename "$f")"
        cred_leak=1
        break 3
      fi
    done
  done
done
[ "$cred_leak" = "0" ] && pass "no consumer key material appears in any issue field"

# 2. Titles must be STABLE between runs. A title carrying a live countdown
#    changes daily, so the platform sees a brand-new issue each run: no
#    deduplication, no age tracking, and an alert every day for one problem.
#    The expiring-key title is the one that used to do this.
if jq -e 'any(.[]; .title | test("expires in [0-9]+ day"))' \
     "$ARTIFACTS/pos-creds/api_credentials_issues.json" >/dev/null 2>&1; then
  fail "no issue title contains a live day countdown" \
       "titles free of 'expires in <N> day'" \
       "$(jq -r '.[] | select(.title | test("expires in [0-9]+ day")) | .title' "$ARTIFACTS/pos-creds/api_credentials_issues.json")"
else
  pass "no issue title contains a live day countdown"
fi
# The countdown still belongs in the details and actual fields, which are
# expected to reflect the current state.
if jq -e 'any(.[]; .issue_type == "credential_expiring" and (.details | test("expires in [0-9]+ day")))' \
     "$ARTIFACTS/pos-creds/api_credentials_issues.json" >/dev/null 2>&1; then
  pass "the day countdown is retained in the issue details"
else
  fail "the day countdown is retained in the issue details" \
       "details naming the remaining days" \
       "$(jq -r '.[] | select(.issue_type=="credential_expiring") | .details' "$ARTIFACTS/pos-creds/api_credentials_issues.json" | head -c 160)"
fi
# Sweep every title produced anywhere in this run for a live countdown.
countdown_hits=0
for f in "$ARTIFACTS"/*/*_issues.json; do
  [ -f "$f" ] || continue
  if jq -e 'any(.[]; .title | test("(expires|expired) in [0-9]+ day|[0-9]+ day\\(s\\) ago"))' "$f" >/dev/null 2>&1; then
    countdown_hits=$((countdown_hits + 1))
    printf '        %s: %s\n' "$(basename "$(dirname "$f")")" \
      "$(jq -r '.[] | select(.title | test("(expires|expired) in [0-9]+ day|[0-9]+ day\\(s\\) ago")) | .title' "$f" | head -1)"
  fi
done
if [ "$countdown_hits" = "0" ]; then
  pass "no title in any check carries a per-run countdown"
else
  fail "no title in any check carries a per-run countdown" "0 files" "$countdown_hits file(s), listed above"
fi

section "runbook shape: discovery is setup, every task can raise a finding"
# A task is a unit of operator attention. Discovery enumerates; it raises no
# finding a check does not already raise, so it belongs in setup -- where an
# unreadable organization is ONE error instead of five.
# Scope to the *** Tasks *** section: keyword definitions also start at column 0,
# so an unscoped grep would match the setup keyword and fail spuriously.
tasks_section="$(awk '/^\*\*\* Tasks \*\*\*/{f=1;next} /^\*\*\* Keywords \*\*\*/{f=0} f' "$RUNBOOK")"
if printf '%s' "$tasks_section" | grep -qE '^Discover Apigee'; then
  fail "discovery is not a task" "no task heading starting 'Discover Apigee'" \
       "$(printf '%s' "$tasks_section" | grep -E '^Discover Apigee' | head -1)"
else
  pass "discovery is not a task"
fi
if awk '/^\*\*\* Keywords \*\*\*/,0' "$RUNBOOK" | grep -q '^Discover Apigee Entitlements'; then
  pass "discovery is a keyword invoked from setup"
else
  fail "discovery is a keyword invoked from setup" "keyword defined in *** Keywords ***" "absent"
fi
if awk '/^Suite Initialization/,/^Discover Apigee Entitlements/' "$RUNBOOK" | grep -q 'Discover Apigee Entitlements'; then
  pass "Suite Initialization calls discovery"
else
  fail "Suite Initialization calls discovery" "a call in Suite Initialization" "absent"
fi
# Setup must abort rather than let four checks fail on the same root cause.
# BOTH unreadable branches have to abort -- unreadable organization and missing
# status file -- so require a Fail in each rather than merely one in the
# keyword, which a mutation removing only one would still satisfy.
discover_kw="$(awk '/^Discover Apigee Entitlements/,0' "$RUNBOOK")"
n_fail="$(printf '%s' "$discover_kw" | grep -cE '^\s+Fail\s')"
if [ "$n_fail" -ge 2 ]; then
  pass "both unreadable branches of setup discovery abort the suite"
else
  fail "both unreadable branches of setup discovery abort the suite" \
       "2 Fail statements (unreadable org, missing status file)" "$n_fail"
fi
# Each abort must be preceded by an issue, or the run aborts with no explanation.
n_issue="$(printf '%s' "$discover_kw" | grep -cE '^\s+RW\.Core\.Add Issue')"
if [ "$n_issue" -ge 2 ]; then
  pass "setup discovery raises an issue before each abort"
else
  fail "setup discovery raises an issue before each abort" "2 Add Issue calls" "$n_issue"
fi
# Every remaining task must be able to produce a finding.
task_count="$(grep -cE '^Check Apigee' "$RUNBOOK")"
if [ "$task_count" = "4" ]; then pass "4 tasks remain, all of them checks"
else fail "4 tasks remain, all of them checks" "4" "$task_count"; fi

section "developer_list_truncated moved to the task that owns developer findings"
# Truncation means the developers that WERE returned are analysed normally and
# their findings are real -- the list is just incomplete. Reporting it as an
# access failure would discard those real findings.
mkdir -p "$ARTIFACTS/fixtures-trunc"
cat > "$ARTIFACTS/fixtures-trunc/organizations" <<'EOF'
{"organizations":[{"organization":"testorg","projectId":"proj-under-test","location":"us-west1"}]}
EOF
cat > "$ARTIFACTS/fixtures-trunc/organizations_testorg_apiproducts" <<'EOF'
{"apiProduct":[{"name":"p1","displayName":"P1","approvalType":"manual","quota":"10","quotaInterval":"1","quotaTimeUnit":"minute"}]}
EOF
cat > "$ARTIFACTS/fixtures-trunc/organizations_testorg_apps" <<'EOF'
{"app":[{"name":"a1","appId":"a1","developerId":"dev2","status":"approved",
  "credentials":[{"consumerKey":"K1","status":"approved","expiresAt":"-1",
    "apiProducts":[{"apiproduct":"p1","status":"approved"}]}]}]}
EOF
cat > "$ARTIFACTS/fixtures-trunc/organizations_testorg_developers" <<'EOF'
{"developer":[{"developerId":"dev1","email":"a@example.com","status":"active"},
              {"developerId":"dev2","email":"b@example.com","status":"inactive"}]}
EOF
echo '{"environment":[]}' > "$ARTIFACTS/fixtures-trunc/organizations_testorg_environments"
# Page size 2 with 2 developers hits the cap; products and apps hold 1 each so
# their pagination terminates and only the developer list is truncated.
run_check "$ARTIFACTS/trunc" "$ARTIFACTS/fixtures-trunc" check_developer_status.sh "APIGEE_PAGE_SIZE=2"
assert_exit_zero "$ARTIFACTS/trunc" "check_developer_status (truncated)"
assert_has_type "$ARTIFACTS/trunc/developer_status_issues.json" "developer_list_truncated" "check_developer_status (truncated)"
# The real finding must survive alongside it.
assert_has_type "$ARTIFACTS/trunc/developer_status_issues.json" "developer_status_drift" "check_developer_status (truncated)"
# Truncation is incompleteness, not inaccessibility.
assert_access "$ARTIFACTS/trunc/developer_status_status.json" "true" "check_developer_status (truncated)"
# And discovery no longer duplicates it.
if grep -q 'developer_list_truncated' "$BUNDLE_DIR/discover_entitlements.sh"; then
  fail "discovery no longer emits developer_list_truncated" "absent from discover_entitlements.sh" "still present"
else
  pass "discovery no longer emits developer_list_truncated"
fi

section "SLI removed from generation, sli.robot retained"
GENRULE="$BUNDLE_DIR/.runwhen/generation-rules/gcp-apigee-product-governance.yaml"
if grep -qE '^\s*-\s*type:\s*sli\s*$' "$GENRULE"; then
  fail "the generation rule no longer emits an SLI" "no '- type: sli' entry" "still present"
else
  pass "the generation rule no longer emits an SLI"
fi
if [ -f "$BUNDLE_DIR/.runwhen/templates/gcp-apigee-product-governance-sli.yaml" ]; then
  fail "the SLI template is removed" "absent" "still present"
else
  pass "the SLI template is removed"
fi
# Kept on purpose: reintroducing the SLI should be a generation-rule edit, not
# a rewrite, and the robot stays covered by this suite's script assertions.
if [ -f "$BUNDLE_DIR/sli.robot" ]; then
  pass "sli.robot is retained for reintroduction"
else
  fail "sli.robot is retained for reintroduction" "present" "deleted"
fi

section "org-to-project mapping: a credential seeing many orgs picks the right one"
# GET /v1/organizations returns every org the SERVICE ACCOUNT can see; there is
# no ?parent=projects/... filter. These bundles are designed around a credential
# shared across a shared org, so positional selection would silently audit
# another project -- a run that SUCCEEDS and is confidently wrong.
mkdir -p "$ARTIFACTS/fixtures-multiorg"
cat > "$ARTIFACTS/fixtures-multiorg/organizations" <<'EOF'
{"organizations":[
 {"organization":"alpha-org","projectId":"alpha-project","location":"us-west1"},
 {"organization":"beta-org","projectId":"beta-project","location":"us-west1"},
 {"organization":"gamma-org","projectId":"gamma-project","location":"us-west1"}
]}
EOF
for o in alpha beta gamma; do
  printf '{"apiProduct":[{"name":"%s-prod","approvalType":"auto"}]}\n' "$o" \
    > "$ARTIFACTS/fixtures-multiorg/organizations_${o}-org_apiproducts"
  echo '{"app":[]}'       > "$ARTIFACTS/fixtures-multiorg/organizations_${o}-org_apps"
  echo '{"developer":[]}' > "$ARTIFACTS/fixtures-multiorg/organizations_${o}-org_developers"
  echo '{"environment":[]}' > "$ARTIFACTS/fixtures-multiorg/organizations_${o}-org_environments"
done
# Each project must resolve to ITS OWN org, not the first in the list.
for proj in alpha beta gamma; do
  run_check "$ARTIFACTS/map-$proj" "$ARTIFACTS/fixtures-multiorg" check_api_products.sh \
    "APIGEE_ORG_OVERRIDE=" "GCP_PROJECT_ID_OVERRIDE=$proj-project"
  got="$(jq -r '.[0].products[0] // "none"' "$ARTIFACTS/map-$proj/api_products_issues.json" 2>/dev/null)"
  if [ "$got" = "$proj-prod" ]; then
    pass "$proj-project resolves to $proj-org, not the first org listed"
  else
    fail "$proj-project resolves to $proj-org, not the first org listed" "$proj-prod" "$got"
  fi
done
# A project with no org must not adopt someone else's.
run_check "$ARTIFACTS/map-none" "$ARTIFACTS/fixtures-multiorg" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=" "GCP_PROJECT_ID_OVERRIDE=unmapped-project"
# Under the org gate this is an error, not a state: reaching it means the bundle
# was pointed at a project that has no organization.
assert_access "$ARTIFACTS/map-none/api_products_status.json" "false" "a project with no org (3 others visible)"
assert_empty "$ARTIFACTS/map-none/api_products_issues.json" "a project with no org (3 others visible)"

# An EXPLICIT APIGEE_ORG is validated, not trusted. It reaches the SLX from
# custom.APIGEE_ORG, a WORKSPACE-level value, so in a multi-project workspace
# every project's SLX receives the same org.
run_check "$ARTIFACTS/map-wrong" "$ARTIFACTS/fixtures-multiorg" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=gamma-org" "GCP_PROJECT_ID_OVERRIDE=alpha-project"
assert_exit_zero "$ARTIFACTS/map-wrong" "check_api_products (org belongs to another project)"
assert_access "$ARTIFACTS/map-wrong/api_products_status.json" "false" "check_api_products (org belongs to another project)"
assert_empty "$ARTIFACTS/map-wrong/api_products_issues.json" "check_api_products (org belongs to another project)"
if grep -q "belongs to project 'gamma-project'" "$ARTIFACTS/map-wrong/api_products_status.json" 2>/dev/null; then
  pass "the mismatch reason names the owning project"
else
  fail "the mismatch reason names the owning project" "reason naming gamma-project" \
       "$(jq -r '.reason' "$ARTIFACTS/map-wrong/api_products_status.json" 2>/dev/null)"
fi
# An explicit org that DOES belong to the project is accepted.
run_check "$ARTIFACTS/map-right" "$ARTIFACTS/fixtures-multiorg" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=alpha-org" "GCP_PROJECT_ID_OVERRIDE=alpha-project"
assert_access "$ARTIFACTS/map-right/api_products_status.json" "true" "check_api_products (org belongs to this project)"
assert_has_type "$ARTIFACTS/map-right/api_products_issues.json" "auto_approval" "check_api_products (org belongs to this project)"

section "regression: organization resolution filters on projectId"
run_check "$ARTIFACTS/reg-orgres" "$ARTIFACTS/fixtures-broken" discover_entitlements.sh "APIGEE_ORG_OVERRIDE="
resolved="$(jq -r '.org' "$ARTIFACTS/reg-orgres/entitlements_discovery.json" 2>/dev/null || echo missing)"
if [ "$resolved" = "testorg" ]; then
  pass "resolves the org bound to the project, not the first one listed"
else
  fail "resolves the org bound to the project, not the first one listed" "testorg" "$resolved"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -gt 0 ]; then
  printf '\033[31mFAILED\033[0m: %d of %d assertions failed.\n' "$FAILURES" "$CHECKS"
  printf 'Artifacts preserved at: %s\n' "$ARTIFACTS"
  printf 'Each case directory holds stdout.txt, stderr.txt, exit_code.txt, requested-urls.txt and the JSON outputs.\n'
  exit 1
fi

printf '\033[32mPASSED\033[0m: all %d assertions passed.\n' "$CHECKS"
if [ "${KEEP_ARTIFACTS:-0}" = "1" ]; then
  printf 'Artifacts preserved at: %s\n' "$ARTIFACTS"
else
  rm -rf "$ARTIFACTS"
fi
