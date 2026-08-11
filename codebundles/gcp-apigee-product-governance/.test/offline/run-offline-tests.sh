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
  # apps.list returns a nextPageToken; the second page must be fetched or the
  # apps on it are invisible and their products look orphaned.
  local d="$1"; mkdir -p "$d"; write_orgs_fixture "$d"
  cat > "$d/organizations_testorg_apiproducts" <<'EOF'
{"apiProduct":[{"name":"page2-prod","displayName":"Referenced only from page 2","approvalType":"manual","quota":"10","quotaInterval":"1","quotaTimeUnit":"minute"}]}
EOF
  cat > "$d/organizations_testorg_apps" <<'EOF'
{"app":[{"name":"page1-app","appId":"p1","developerId":"dev1","status":"approved",
  "credentials":[{"consumerKey":"KEYPAGE1","status":"approved","expiresAt":"-1","apiProducts":[]}]}],
 "nextPageToken":"PAGE2"}
EOF
  # Page 2 holds the only credential referencing page2-prod. A listing that
  # stops at page 1 reports that product as orphaned.
  cat > "$d/organizations_testorg_apps__page_PAGE2" <<'EOF'
{"app":[{"name":"page2-app","appId":"p2","developerId":"dev1","status":"approved",
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
if jq -e 'any(.[]; .title | test("expires in [0-9]+ day"))' "$ARTIFACTS/pos-creds/api_credentials_issues.json" >/dev/null 2>&1; then
  pass "check_app_credentials renders a numeric day count in the expiring title"
else
  fail "check_app_credentials renders a numeric day count in the expiring title" \
       "title matching 'expires in <N> day'" \
       "$(jq -r '.[] | select(.issue_type=="credential_expiring") | .title' "$ARTIFACTS/pos-creds/api_credentials_issues.json" 2>/dev/null)"
fi
if jq -e 'all(.[]; (.app // "") != "")' "$ARTIFACTS/pos-creds/api_credentials_issues.json" >/dev/null 2>&1; then
  pass "check_app_credentials populates the app field on every issue"
else
  fail "check_app_credentials populates the app field on every issue" \
       "non-empty .app on all issues" \
       "$(jq -c '[.[] | {issue_type, app}]' "$ARTIFACTS/pos-creds/api_credentials_issues.json" 2>/dev/null)"
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
n_orphans="$(jq '[.[] | select(.issue_type == "orphaned_product")] | length' "$ARTIFACTS/reg-noref/orphaned_entitlements_issues.json" 2>/dev/null || echo 0)"
if [ "$n_orphans" = "3" ]; then pass "all 3 unreferenced products are reported"
else fail "all 3 unreferenced products are reported" "3" "$n_orphans"; fi

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

section "regression: paginated app list"
run_check "$ARTIFACTS/reg-paging" "$ARTIFACTS/fixtures-paging" check_orphaned_entitlements.sh
assert_exit_zero "$ARTIFACTS/reg-paging" "check_orphaned_entitlements"
assert_url_matches "$ARTIFACTS/reg-paging" "pageToken=PAGE2" "check_orphaned_entitlements"
# page2-prod is referenced only by an app on page 2. Stopping at page 1 would
# report it as orphaned, so its absence proves the second page was consumed.
assert_lacks_type "$ARTIFACTS/reg-paging/orphaned_entitlements_issues.json" "orphaned_product" "check_orphaned_entitlements (paged)"

section "regression: a page token that never advances must not hang"
mkdir -p "$ARTIFACTS/fixtures-loop"
cp "$ARTIFACTS/fixtures-paging"/* "$ARTIFACTS/fixtures-loop"/ 2>/dev/null
# Page 2 hands back the same token it was fetched with.
cat > "$ARTIFACTS/fixtures-loop/organizations_testorg_apps__page_PAGE2" <<'EOF'
{"app":[],"nextPageToken":"PAGE2"}
EOF
run_check "$ARTIFACTS/reg-loop" "$ARTIFACTS/fixtures-loop" check_orphaned_entitlements.sh
assert_exit_zero "$ARTIFACTS/reg-loop" "check_orphaned_entitlements (looping token)"
assert_access "$ARTIFACTS/reg-loop/orphaned_entitlements_status.json" "false" "check_orphaned_entitlements (looping token)"

section "INTERIM applicability: determination of absence vs failure to determine"
# The bundle is generated for every GCP project, so most projects it runs
# against have no Apigee at all. Those must not go red -- but "we asked and the
# answer is no" and "we could not ask" must never collapse into each other.
# Scenario F: definite absence, empty list.
# Scenario G: definite absence, Apigee API never enabled.
# Scenario H: failure to determine -- must still raise and score 0.

# --- F: HTTP 200, organization list holds nothing for this project -----------
mkdir -p "$ARTIFACTS/fixtures-noapigee"
cat > "$ARTIFACTS/fixtures-noapigee/organizations" <<'EOF'
{"organizations":[{"organization":"someone-elses-org","projectId":"unrelated-project","location":"us-west1"}]}
EOF
run_check "$ARTIFACTS/na-products" "$ARTIFACTS/fixtures-noapigee" check_api_products.sh "APIGEE_ORG_OVERRIDE="
assert_exit_zero "$ARTIFACTS/na-products" "check_api_products (F: no org for project)"
assert_empty "$ARTIFACTS/na-products/api_products_issues.json" "check_api_products (F: no org for project)"
assert_access "$ARTIFACTS/na-products/api_products_status.json" "true" "check_api_products (F)"
assert_applicable "$ARTIFACTS/na-products/api_products_status.json" "false" "check_api_products (F)"

run_check "$ARTIFACTS/na-discover" "$ARTIFACTS/fixtures-noapigee" discover_entitlements.sh "APIGEE_ORG_OVERRIDE="
assert_exit_zero "$ARTIFACTS/na-discover" "discover_entitlements (F)"
assert_empty "$ARTIFACTS/na-discover/entitlements_discovery_issues.json" "discover_entitlements (F)"
assert_applicable "$ARTIFACTS/na-discover/entitlements_discovery_status.json" "false" "discover_entitlements (F)"
assert_applicable "$ARTIFACTS/na-discover/entitlements_discovery.json" "false" "the discovery topology (F)"
# The empty topology must carry real empty collections, not nulls: downstream
# jq iterating .api_products[] would abort with "Cannot iterate over null".
if jq -e '(.api_products | type == "array") and (.developers | type == "array")
          and (.apps | type == "array") and (.environments | type == "array")' \
     "$ARTIFACTS/na-discover/entitlements_discovery.json" >/dev/null 2>&1; then
  pass "the not-applicable topology is well-formed and empty, not {}"
else
  fail "the not-applicable topology is well-formed and empty, not {}" \
       "api_products/developers/apps/environments all arrays" \
       "$(jq -c 'to_entries|map({(.key):(.value|type)})|add' "$ARTIFACTS/na-discover/entitlements_discovery.json" 2>/dev/null)"
fi

# The shape a real project without Apigee returns. Recorded from
# GET /v1/organizations against runwhen-nonprod-sandbox: a bare {} with no
# "organizations" key at all -- a different jq path from "key present, no match".
mkdir -p "$ARTIFACTS/fixtures-emptyorgs"
printf '{}\n' > "$ARTIFACTS/fixtures-emptyorgs/organizations"
run_check "$ARTIFACTS/na-empty" "$ARTIFACTS/fixtures-emptyorgs" check_api_products.sh "APIGEE_ORG_OVERRIDE="
assert_exit_zero "$ARTIFACTS/na-empty" "check_api_products (F: bare {})"
assert_empty "$ARTIFACTS/na-empty/api_products_issues.json" "check_api_products (F: bare {})"
assert_applicable "$ARTIFACTS/na-empty/api_products_status.json" "false" "check_api_products (F: bare {})"

# --- G: the Apigee API has never been enabled on this project ----------------
# A 403 whose body says SERVICE_DISABLED. No organization can exist where the
# API was never switched on, so this is an answer, not a failure.
API_DISABLED_BODY='{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Apigee API has not been used in project 12345 before or it is disabled.","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"googleapis.com"}]}}'
run_check "$ARTIFACTS/na-disabled" "$ARTIFACTS/fixtures-noapigee" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=" "ERROR_STATUS=403" "ERROR_BODY=$API_DISABLED_BODY"
assert_exit_zero "$ARTIFACTS/na-disabled" "check_api_products (G: API disabled)"
assert_empty "$ARTIFACTS/na-disabled/api_products_issues.json" "check_api_products (G: API disabled)"
assert_access "$ARTIFACTS/na-disabled/api_products_status.json" "true" "check_api_products (G)"
assert_applicable "$ARTIFACTS/na-disabled/api_products_status.json" "false" "check_api_products (G)"

run_check "$ARTIFACTS/na-disabled-disc" "$ARTIFACTS/fixtures-noapigee" discover_entitlements.sh \
  "APIGEE_ORG_OVERRIDE=" "ERROR_STATUS=403" "ERROR_BODY=$API_DISABLED_BODY"
assert_exit_zero "$ARTIFACTS/na-disabled-disc" "discover_entitlements (G)"
assert_empty "$ARTIFACTS/na-disabled-disc/entitlements_discovery_issues.json" "discover_entitlements (G)"
assert_applicable "$ARTIFACTS/na-disabled-disc/entitlements_discovery_status.json" "false" "discover_entitlements (G)"

# 404 spelt "API has not been used" is the same determination.
run_check "$ARTIFACTS/na-disabled-404" "$ARTIFACTS/fixtures-noapigee" check_api_products.sh \
  "APIGEE_ORG_OVERRIDE=" "ERROR_STATUS=404" \
  "ERROR_BODY={\"error\":{\"code\":404,\"message\":\"Apigee API has not been used in project foo before\"}}"
assert_applicable "$ARTIFACTS/na-disabled-404/api_products_status.json" "false" "check_api_products (G: 404 variant)"

# --- H: failure to determine -- must NOT be reported as absence --------------
# A plain permission denial carries no SERVICE_DISABLED marker. Widening the
# absence match to accept bare PERMISSION_DENIED would make an
# under-permissioned service account report every project as "no Apigee here"
# and score 1.0 -- the healthy-while-blind defect this bundle removed.
run_check "$ARTIFACTS/na-denied" "$ARTIFACTS/fixtures-noapigee" check_api_products.sh "APIGEE_ORG_OVERRIDE=" "API_FAIL=1"
assert_exit_zero "$ARTIFACTS/na-denied" "check_api_products (H: permission denied)"
assert_access "$ARTIFACTS/na-denied/api_products_status.json" "false" "check_api_products (H)"
assert_applicable "$ARTIFACTS/na-denied/api_products_status.json" "true" "check_api_products (H: NOT marked absent)"

run_check "$ARTIFACTS/na-denied-disc" "$ARTIFACTS/fixtures-noapigee" discover_entitlements.sh "APIGEE_ORG_OVERRIDE=" "API_FAIL=1"
assert_exit_zero "$ARTIFACTS/na-denied-disc" "discover_entitlements (H)"
assert_access "$ARTIFACTS/na-denied-disc/entitlements_discovery_status.json" "false" "discover_entitlements (H)"
assert_applicable "$ARTIFACTS/na-denied-disc/entitlements_discovery_status.json" "true" "discover_entitlements (H: NOT marked absent)"
assert_has_type "$ARTIFACTS/na-denied-disc/entitlements_discovery_issues.json" "discovery_access_error" "discover_entitlements (H)"

# And an explicitly-set organization that cannot be read must also score 0 --
# the path the E2E run exercised with APIGEE_ORG=denied-org-does-not-exist.
run_check "$ARTIFACTS/na-badorg" "$ARTIFACTS/fixtures-noapigee" discover_entitlements.sh "APIGEE_ORG_OVERRIDE=denied-org-does-not-exist"
assert_exit_zero "$ARTIFACTS/na-badorg" "discover_entitlements (explicit unreadable org)"
assert_access "$ARTIFACTS/na-badorg/entitlements_discovery_status.json" "false" "discover_entitlements (explicit unreadable org)"
assert_count "$ARTIFACTS/na-badorg/entitlements_discovery_issues.json" 3 "discover_entitlements (explicit unreadable org)"

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
for pair in "entitlements_discovery_issues.json:entitlements_discovery_status.json" \
            "api_products_issues.json:api_products_status.json" \
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
