#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover GCP Cloud Load Balancers and Configurations
#
# Lists all forwarding rules in the GCP project, categorizes each by load
# balancer type (HTTP/S, SSL proxy, TCP proxy, Network), and dumps detailed
# configuration including IP address, ports, target proxy, and backend service.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID      - GCP project ID hosting the load balancers
#
# OUTPUTS:
#   lb_config.json          - Array of enriched load balancer objects
#   lb_discovery_issues.json- JSON array of issues (usually empty on success)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="lb_discovery_issues.json"
CONFIG_FILE="lb_config.json"
issues_json='[]'

echo "Discovering load balancers in project: $GCP_PROJECT_ID"

if ! forwarding_rules=$(gcloud compute forwarding-rules list \
    --project="$GCP_PROJECT_ID" --format=json 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot access forwarding rules for project \`$GCP_PROJECT_ID\`" \
        --arg details "gcloud compute forwarding-rules list failed: $err_msg" \
        --arg severity "4" \
        --arg expected "Forwarding rules should be retrievable to assess load balancer health" \
        --arg actual "Listing forwarding rules failed: $err_msg" \
        --arg next_steps "Verify the service account has compute.forwardingRules.list permission and that the Compute Engine API is enabled." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$CONFIG_FILE"
    echo "Discovery failed. Issues written to $ISSUES_FILE"
    exit 0
fi

if [ "$(echo "$forwarding_rules" | jq 'length')" -eq 0 ]; then
    echo "No load balancers (forwarding rules) found in project $GCP_PROJECT_ID."
    echo "[]" > "$CONFIG_FILE"
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# Build an enriched config dump: for each forwarding rule classify by LB type
# and capture target proxy / backend service references.
echo "$forwarding_rules" | jq -c '
  [ .[] | . as $fr |
    {
      name: $fr.name,
      region: ($fr.region // $fr.selfLink // "" | split("/") | .[-1]),
      ip_address: $fr.IPAddress,
      ip_protocol: $fr.IPProtocol,
      ports: ($fr.ports // []),
      port_range: ($fr.portRange // ""),
      load_balancing_scheme: $fr.loadBalancingScheme,
      network_tier: $fr.networkTier,
      target: $fr.target,
      backend_service: $fr.backendService,
      type: (
        if ($fr.target | tostring | contains("targetHttpsProxies")) then "HTTPS"
        elif ($fr.target | tostring | contains("targetHttpProxies")) then "HTTP"
        elif ($fr.target | tostring | contains("targetSslProxies")) then "SSL"
        elif ($fr.target | tostring | contains("targetTcpProxies")) then "TCP"
        else "NETWORK"
        end
      ),
      target_proxy: ($fr.target | tostring | split("/") | .[-1]),
      project: $GCP_PROJECT_ID
    }
  ]
' --arg GCP_PROJECT_ID "$GCP_PROJECT_ID" > "$CONFIG_FILE"

count=$(echo "$forwarding_rules" | jq 'length')
echo "Discovered $count load balancer(s) in project $GCP_PROJECT_ID."
jq -r '.[] | "  \(.name)  type=\(.type)  ip=\(.ip_address)  region=\(.region)"' "$CONFIG_FILE"

echo "$issues_json" > "$ISSUES_FILE"
echo "Configuration dump written to $CONFIG_FILE"
