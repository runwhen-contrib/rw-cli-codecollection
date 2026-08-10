#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Canned Apigee Management API responses for the offline tier.
#
# PROVENANCE -- read before editing.
#
# These response shapes are derived from two sources that are INDEPENDENT of
# this codebundle's implementation:
#
#   1. The Apigee v1 API discovery document:
#        https://apigee.googleapis.com/$discovery/rest?version=v1
#   2. Response shapes observed against a live Apigee X organization during PR
#        #745 review.
#
# They are deliberately NOT derived from what the check scripts expect. An
# earlier version of this fixture set was written from the implementation and
# consequently passed while the implementation was wrong: it used
# `attachments` for envgroup attachments and `networkConfig.network` for the
# org network, so the H2 and H3 defects were invisible offline and only
# surfaced against a real org.
#
# When adding a fixture, take the shape from the discovery document or a
# recorded real response. If a fixture is ever "fixed" to make a test pass,
# that is the bug reproducing itself.
#
# Traps intentionally reproduced here:
#   - /environments returns a BARE ARRAY, not an object
#   - envgroup attachments come back under `environmentGroupAttachments`,
#     while instance attachments use `attachments`
#   - the organization has `authorizedNetwork` and NO `networkConfig`
#   - `peeringCidrRange` is a per-INSTANCE field
#   - alias `expiryDate` is epoch MILLISECONDS as an int64 string
#   - a keystore's aliases are an array of STRINGS on the keystore itself
# -----------------------------------------------------------------------------
set -euo pipefail

F="${1:?usage: fixtures.sh <output-dir> [org]}"
ORG="${2:-test-org}"

rm -rf "${F}"
mkdir -p "${F}"
put() { cat > "${F}/$1.json"; }

# --- Organization -------------------------------------------------------------
# authorizedNetwork at the top level; networkConfig does not exist on an org.
put "organizations" <<EOF
{"organizations":[{"organization":"organizations/${ORG}","projects":["test-project"]}]}
EOF

put "organizations_${ORG}" <<EOF
{"name":"${ORG}","state":"ACTIVE","runtimeType":"CLOUD",
 "authorizedNetwork":"apigee-net","disableVpcPeering":false}
EOF

# --- Environments: a BARE ARRAY ----------------------------------------------
put "organizations_${ORG}_environments" <<EOF
["env-a","env-b"]
EOF

put "organizations_${ORG}_environments_env-a" <<EOF
{"name":"env-a","state":"ACTIVE"}
EOF
put "organizations_${ORG}_environments_env-b" <<EOF
{"name":"env-b","state":"ACTIVE"}
EOF

# --- Instances: peeringCidrRange is per-instance ------------------------------
put "organizations_${ORG}_instances" <<EOF
{"instances":[
 {"name":"organizations/${ORG}/instances/inst-1","location":"us-west1","state":"ACTIVE","host":"10.0.0.1","peeringCidrRange":"SLASH_22"},
 {"name":"organizations/${ORG}/instances/inst-2","location":"us-central1","state":"ACTIVE","host":"10.0.1.1","peeringCidrRange":"SLASH_22"}]}
EOF

# Instance attachments DO use `attachments`.
put "organizations_${ORG}_instances_inst-1_attachments" <<EOF
{"attachments":[{"name":"att-1","environment":"env-a"}]}
EOF
put "organizations_${ORG}_instances_inst-2_attachments" <<EOF
{"attachments":[{"name":"att-2","environment":"env-a"}]}
EOF

# --- Environment groups -------------------------------------------------------
put "organizations_${ORG}_envgroups" <<EOF
{"environmentGroups":[
 {"name":"organizations/${ORG}/envgroups/eg-main","hostnames":["api.example.com"],"state":"ACTIVE"},
 {"name":"organizations/${ORG}/envgroups/eg-orphan","hostnames":["orphan.example.com"],"state":"ACTIVE"}]}
EOF

# Envgroup attachments use `environmentGroupAttachments` -- NOT `attachments`.
put "organizations_${ORG}_envgroups_eg-main_attachments" <<EOF
{"environmentGroupAttachments":[
 {"name":"59a40bda-0000-0000-0000-000000000000","environment":"env-a","environmentGroupId":"eg-main"}]}
EOF
put "organizations_${ORG}_envgroups_eg-orphan_attachments" <<EOF
{"environmentGroupAttachments":[]}
EOF

# --- Keystore: aliases are strings on the keystore; expiry is epoch millis ----
EXPIRING_MS=$(( ($(date +%s) + 5 * 86400) * 1000 ))
put "organizations_${ORG}_environments_env-a_keystores" <<EOF
["ks-1"]
EOF
put "organizations_${ORG}_environments_env-a_keystores_ks-1" <<EOF
{"name":"ks-1","aliases":["alias-expiring"]}
EOF
put "organizations_${ORG}_environments_env-a_keystores_ks-1_aliases_alias-expiring" <<EOF
{"alias":"alias-expiring","type":"KEY_CERT",
 "certsInfo":{"certInfo":[
   {"subject":"CN=api.example.com","expiryDate":"${EXPIRING_MS}","validFrom":"0","isValid":"Yes"}]}}
EOF

# --- Target servers -----------------------------------------------------------
put "organizations_${ORG}_environments_env-a_targetservers" <<EOF
["ts-1"]
EOF
# isEnabled:false is the jq `//` trap -- `.isEnabled // true` reports it enabled.
put "organizations_${ORG}_environments_env-a_targetservers_ts-1" <<EOF
{"name":"ts-1","host":"backend.invalid","port":443,"isEnabled":false}
EOF

# --- gcloud-side fixtures -----------------------------------------------------
put "_gcloud_vpc_peerings" <<EOF
[{"network":"apigee-net","reservedPeeringRanges":["apigee-peering"]}]
EOF
put "_gcloud_psc" <<EOF
[]
EOF

echo "wrote $(ls "${F}" | wc -l | xargs) fixtures to ${F}"
