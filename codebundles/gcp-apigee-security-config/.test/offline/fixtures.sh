#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Canned Apigee Management API and Cloud Monitoring responses for the offline
# tier.
#
# PROVENANCE -- read before editing.
#
# These response shapes come from the Apigee v1 API discovery document:
#
#     https://apigee.googleapis.com/$discovery/rest?version=v1
#
# and NOT from what the check scripts expect to see. That distinction is the
# whole point. The sibling gcp-apigee-environment-health bundle wrote its first
# fixture set from its own implementation and it consequently passed while the
# implementation was wrong; the defects only surfaced against a real org.
#
# When adding a fixture, take the shape from the discovery document or from a
# recorded real response. If a fixture is ever "fixed" to make a test pass, that
# is the bug reproducing itself.
#
# Traps deliberately reproduced here, each verified against the discovery doc:
#
#   - The DOCUMENTED list endpoints wrap their array in a SINGULAR field name,
#     not the plural one the URL suggests:
#         /apiproducts          -> {"apiProduct": [...]}
#         /developers           -> {"developer": [...]}
#         /developers/{d}/apps  -> {"app": [...]}
#
#   - /environments and /environments/{env}/targetservers have NO entry in the
#     discovery document at all and return a BARE ARRAY OF STRINGS. Reading
#     `.name` off a string errors, the field comes back empty, and the loop skips
#     every element -- which is how check_target_vhost_config.sh came to report a
#     plaintext backend for every target server without ever reading one.
#
#   - TLS configuration is NOT on the target server list response. It is on the
#     per-target-server GET (GoogleCloudApigeeV1TargetServer), under `sSLInfo`
#     with that exact capitalisation.
# -----------------------------------------------------------------------------
set -euo pipefail

F="${1:?usage: fixtures.sh <output-dir> [org]}"
ORG="${2:-test-org}"

rm -rf "${F}"
mkdir -p "${F}"
put() { cat > "${F}/$1.json"; }

# --- API products: DOCUMENTED, field is `apiProduct` (singular) ----------------
# product-open      : no quota at all           -> no_quota
# product-huge      : quota above the threshold -> excessive
# product-auto      : approvalType auto         -> auto_approval, AND no quota
# product-ok        : sensible quota, manual    -> nothing
put "organizations_${ORG}_apiproducts" <<'EOF'
{"apiProduct":[
 {"name":"product-open","displayName":"Open","approvalType":"manual"},
 {"name":"product-huge","displayName":"Huge","approvalType":"manual",
  "quota":"5000000","quotaInterval":"1","quotaTimeUnit":"minute"},
 {"name":"product-auto","displayName":"Auto","approvalType":"auto"},
 {"name":"product-ok","displayName":"Fine","approvalType":"manual",
  "quota":"1000","quotaInterval":"1","quotaTimeUnit":"minute"}]}
EOF

# --- Developers and apps: DOCUMENTED, fields `developer` and `app` -------------
put "organizations_${ORG}_developers" <<'EOF'
{"developer":[
 {"email":"dev-a@example.com","developerId":"id-a","status":"active"},
 {"email":"dev-b@example.com","developerId":"id-b","status":"active"}]}
EOF

put "organizations_${ORG}_developers_dev-a@example.com_apps" <<'EOF'
{"app":[{"name":"app-wide"},{"name":"app-tidy"}]}
EOF
put "organizations_${ORG}_developers_dev-b@example.com_apps" <<'EOF'
{"app":[{"name":"app-stale"}]}
EOF

# Wildcard app scope AND a wildcard approved key: two DIFFERENT failure modes on
# one app, so a run that collapses them into one issue is visibly wrong.
put "organizations_${ORG}_developers_dev-a@example.com_apps_app-wide" <<'EOF'
{"name":"app-wide","appId":"aaaa","status":"approved","scopes":["read:*"],
 "credentials":[
  {"consumerKey":"CONSUMERKEYAAAA1111","status":"approved","scopes":["admin:*"],
   "apiProducts":[{"apiproduct":"product-open","status":"approved"}]}]}
EOF

put "organizations_${ORG}_developers_dev-a@example.com_apps_app-tidy" <<'EOF'
{"name":"app-tidy","appId":"bbbb","status":"approved","scopes":["read:orders"],
 "credentials":[
  {"consumerKey":"CONSUMERKEYBBBB2222","status":"approved","scopes":["read:orders"],
   "apiProducts":[{"apiproduct":"product-ok","status":"approved"}]}]}
EOF

# A revoked key still attached. Its scopes are wildcard too, but it must NOT be
# counted as an over-broad APPROVED key -- a revoked credential grants nothing.
put "organizations_${ORG}_developers_dev-b@example.com_apps_app-stale" <<'EOF'
{"name":"app-stale","appId":"cccc","status":"approved","scopes":["read:catalog"],
 "credentials":[
  {"consumerKey":"CONSUMERKEYCCCC3333","status":"revoked","scopes":["admin:*"],
   "apiProducts":[{"apiproduct":"product-ok","status":"revoked"}]}]}
EOF

# --- Environments: a BARE ARRAY OF STRINGS ------------------------------------
put "organizations_${ORG}_environments" <<'EOF'
["env-prod","env-stage"]
EOF

# --- Target servers: also a BARE ARRAY OF STRINGS -----------------------------
put "organizations_${ORG}_environments_env-prod_targetservers" <<'EOF'
["ts-plain","ts-secure"]
EOF
put "organizations_${ORG}_environments_env-stage_targetservers" <<'EOF'
["ts-disabled"]
EOF

# --- Target server detail: sSLInfo lives HERE, not on the list ----------------
# No sSLInfo at all -> plaintext.
put "organizations_${ORG}_environments_env-prod_targetservers_ts-plain" <<'EOF'
{"name":"ts-plain","host":"plain.internal","port":80,"isEnabled":true}
EOF
# TLS enabled -> must NOT be flagged. This is the fixture that fails if the
# script reads sSLInfo off the list response instead of this document.
put "organizations_${ORG}_environments_env-prod_targetservers_ts-secure" <<'EOF'
{"name":"ts-secure","host":"secure.internal","port":443,"isEnabled":true,
 "sSLInfo":{"enabled":true,"keyStore":"ks-1","keyAlias":"alias-1","protocols":["TLSv1.2"]}}
EOF
# sSLInfo present but explicitly disabled -- the jq `//` trap: `.enabled // true`
# would read false as true.
put "organizations_${ORG}_environments_env-stage_targetservers_ts-disabled" <<'EOF'
{"name":"ts-disabled","host":"legacy.internal","port":8080,"isEnabled":true,
 "sSLInfo":{"enabled":false}}
EOF

# --- Cloud Monitoring: Apigee security metrics --------------------------------
# Keyed by metric short name; see the curl stub, which reads the metric type out
# of the POST body.
put "_monitoring_score" <<'EOF'
{"timeSeries":[{"points":[{"value":{"doubleValue":55}}]}]}
EOF
put "_monitoring_detected_request_count" <<'EOF'
{"timeSeries":[{"points":[{"value":{"int64Value":"12"}},{"value":{"int64Value":"8"}}]}]}
EOF
# Absent by design: no incident data. Absence must raise NOTHING -- it means
# "not measured", not "measured as zero risk".
put "_monitoring_incident_request_count" <<'EOF'
{}
EOF

echo "wrote $(find "${F}" -name '*.json' -type f | wc -l | xargs) fixtures to ${F}"
