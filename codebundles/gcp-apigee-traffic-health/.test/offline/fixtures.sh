#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Canned Apigee Management API responses for the offline tier.
#
# PROVENANCE -- read before editing.
#
# These response shapes come from the Apigee v1 API discovery document:
#
#     https://apigee.googleapis.com/$discovery/rest?version=v1
#
# and NOT from what discover_metrics_scope.sh expects to see. That distinction
# is the whole point. The sibling gcp-apigee-environment-health bundle wrote its
# first fixture set from its own implementation, and it consequently passed
# while the implementation was wrong -- the defects only surfaced against a real
# org.
#
# When adding a fixture, take the shape from the discovery document or from a
# recorded real response. If a fixture is ever "fixed" to make a test pass, that
# is the bug reproducing itself.
#
# Traps deliberately reproduced here, each verified against the discovery doc:
#
#   - organizations/{org}/apis IS documented
#     (apigee.organizations.apis.list -> GoogleCloudApigeeV1ListApiProxiesResponse)
#     and returns {"proxies":[{"name":...}]}.
#
#   - organizations/{org}/environments has NO entry in the discovery document at
#     all and returns a BARE ARRAY OF STRINGS.
#
#   - organizations/{org}/environments/{env}/targetservers likewise has NO entry
#     and also returns a BARE ARRAY OF STRINGS. discover_metrics_scope.sh used
#     to read `.targetServers[].name` here, which matches no real response, so
#     the target server list was ALWAYS empty and the target performance check
#     evaluated nothing while rendering as passed. A fixture written from the
#     old code would have had a `targetServers` key and hidden that entirely.
# -----------------------------------------------------------------------------
set -euo pipefail

F="${1:?usage: fixtures.sh <output-dir> [org]}"
ORG="${2:-mock-org}"

rm -rf "${F}"
mkdir -p "${F}"
put() { cat > "${F}/$1.json"; }

# --- API proxies: a DOCUMENTED object response --------------------------------
put "organizations_${ORG}_apis" <<'EOF'
{"proxies":[
 {"name":"payments-api","revision":["1","2"],"metaData":{"lastModifiedAt":"1700000000000"}},
 {"name":"orders-api","revision":["3"],"metaData":{"lastModifiedAt":"1700000000000"}},
 {"name":"catalog-api","revision":["1"],"metaData":{"lastModifiedAt":"1700000000000"}}]}
EOF

# --- Environments: a BARE ARRAY OF STRINGS ------------------------------------
put "organizations_${ORG}_environments" <<'EOF'
["prod","staging"]
EOF

# --- Target servers: also a BARE ARRAY OF STRINGS -----------------------------
put "organizations_${ORG}_environments_prod_targetservers" <<'EOF'
["backend-payments","backend-catalog"]
EOF
put "organizations_${ORG}_environments_staging_targetservers" <<'EOF'
[]
EOF

echo "wrote $(find "${F}" -name '*.json' -type f | wc -l | xargs) fixtures to ${F}"
