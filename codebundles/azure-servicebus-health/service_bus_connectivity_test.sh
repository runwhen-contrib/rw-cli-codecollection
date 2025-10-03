#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_connectivity_test.sh
#
#  PURPOSE:
#    Tests connectivity to Service Bus namespace from the current environment
#    and checks for network-related issues
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -euo pipefail

CONN_OUTPUT="service_bus_connectivity.json"
ISSUES_OUTPUT="service_bus_connectivity_issues.json"
echo "{}" > "$CONN_OUTPUT"
echo '{"issues":[]}' > "$ISSUES_OUTPUT"

# ---------------------------------------------------------------------------
# 1) Determine subscription ID
# ---------------------------------------------------------------------------
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "Using current Azure CLI subscription: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using AZURE_RESOURCE_SUBSCRIPTION_ID: $subscription"
fi

az account set --subscription "$subscription"

# ---------------------------------------------------------------------------
# 2) Validate required env vars
# ---------------------------------------------------------------------------
: "${SB_NAMESPACE_NAME:?Must set SB_NAMESPACE_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
# 3) Get Service Bus namespace details
# ---------------------------------------------------------------------------
echo "Getting details for Service Bus namespace: $SB_NAMESPACE_NAME"

namespace_info=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)

# Extract endpoint information
endpoint=$(echo "$namespace_info" | jq -r '.serviceBusEndpoint')
hostname="${endpoint#*://}"
hostname="${hostname%/*}"
echo "Service Bus endpoint hostname: $hostname"

# Get namespace network settings
network_rules=$(az servicebus namespace network-rule list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json 2>/dev/null || echo "{}")

# Get private endpoints
private_endpoints=$(az network private-endpoint list \
  --query "[?contains(privateLinkServiceConnections[].privateLinkServiceId, '$SB_NAMESPACE_NAME')]" \
  -o json 2>/dev/null || echo "[]")

# ---------------------------------------------------------------------------
# 4) Test connectivity using different methods
# ---------------------------------------------------------------------------
echo "Testing connectivity to Service Bus namespace: $SB_NAMESPACE_NAME"

# 4.1) Basic TCP port connectivity test (AMQP - 5671, HTTPS - 443)
echo "Testing TCP connectivity to AMQP port (5671)..."
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$hostname/5671" 2>/dev/null && amqp_port_result="success" || amqp_port_result="failure"

echo "Testing TCP connectivity to HTTPS port (443)..."
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$hostname/443" 2>/dev/null && https_port_result="success" || https_port_result="failure"

# 4.2) DNS resolution test
echo "Testing DNS resolution..."
dns_result=$(nslookup "$hostname" 2>&1) || true
dns_success=$(echo "$dns_result" | grep -q "Non-authoritative answer" && echo "true" || echo "false")

# 4.3) HTTP endpoint check using curl (Service Bus REST API)
echo "Testing HTTPS endpoint..."
timeout 10 curl -s -o /dev/null -w "%{http_code}" "https://$hostname" 2>/dev/null && https_result="success" || https_result="failure"

# 4.4) Network latency test using ping
echo "Testing network latency..."
ping_result=$(ping -c 3 "$hostname" 2>&1) || true
ping_success=$(echo "$ping_result" | grep -q "bytes from" && echo "true" || echo "false")
if [[ "$ping_success" == "true" ]]; then
  avg_latency=$(echo "$ping_result" | grep -oP 'avg=\K[0-9.]+' || echo "unknown")
else
  avg_latency="unknown"
fi

# ---------------------------------------------------------------------------
# 5) Combine connectivity test results
# ---------------------------------------------------------------------------
connectivity_data=$(jq -n \
  --arg hostname "$hostname" \
  --arg amqp_port "$amqp_port_result" \
  --arg https_port "$https_port_result" \
  --arg dns_success "$dns_success" \
  --arg https_result "$https_result" \
  --arg ping_success "$ping_success" \
  --arg avg_latency "$avg_latency" \
  --argjson network_rules "$network_rules" \
  --argjson private_endpoints "$private_endpoints" \
  '{
    hostname: $hostname,
    tests: {
      amqp_port_connectivity: $amqp_port,
      https_port_connectivity: $https_port,
      dns_resolution: $dns_success,
      https_endpoint: $https_result,
      ping: $ping_success,
      average_latency_ms: $avg_latency
    },
    network_rules: $network_rules,
    private_endpoints: $private_endpoints,
    public_network_access: ($network_rules.defaultAction // "Allow")
  }')

echo "$connectivity_data" > "$CONN_OUTPUT"
echo "Connectivity test results saved to $CONN_OUTPUT"

# ---------------------------------------------------------------------------
# 6) Analyze connectivity test results for issues
# ---------------------------------------------------------------------------
echo "Analyzing connectivity test results for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check for AMQP port connectivity
amqp_port_result=$(jq -r '.tests.amqp_port_connectivity' <<< "$connectivity_data")
if [[ "$amqp_port_result" == "failure" ]]; then
  add_issue 2 \
    "AMQP port (5671) connectivity failed for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Check network security groups, firewall rules, and private endpoint configuration" \
    "AMQP connectivity is required for Service Bus clients using the AMQP protocol"
fi

# Check for HTTPS port connectivity
https_port_result=$(jq -r '.tests.https_port_connectivity' <<< "$connectivity_data")
if [[ "$https_port_result" == "failure" ]]; then
  add_issue 2 \
    "HTTPS port (443) connectivity failed for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Check network security groups, firewall rules, and private endpoint configuration" \
    "HTTPS connectivity is required for Service Bus clients using the REST API"
fi

# Check for DNS resolution
dns_success=$(jq -r '.tests.dns_resolution' <<< "$connectivity_data")
if [[ "$dns_success" == "false" ]]; then
  add_issue 2 \
    "DNS resolution failed for Service Bus hostname: $hostname" \
    "Check DNS configuration and private DNS zones if using private endpoints" \
    "DNS resolution is required for Service Bus connectivity"
fi

# Check for high latency
avg_latency=$(jq -r '.tests.average_latency_ms' <<< "$connectivity_data")
if [[ "$avg_latency" != "unknown" && $(echo "$avg_latency > 100" | bc -l) -eq 1 ]]; then
  add_issue 3 \
    "High network latency (${avg_latency}ms) to Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider using a namespace in a region closer to your application or check for network issues" \
    "High latency can impact messaging performance and timeouts"
fi

# Check for IP filtering without current IP
public_network_access=$(jq -r '.public_network_access' <<< "$connectivity_data")
if [[ "$public_network_access" == "Deny" ]]; then
  ip_rules_count=$(jq '.network_rules.ipRules | length' <<< "$connectivity_data")
  private_endpoint_count=$(jq '.private_endpoints | length' <<< "$connectivity_data")
  
  if [[ "$ip_rules_count" -eq 0 && "$private_endpoint_count" -eq 0 ]]; then
    add_issue 1 \
      "Service Bus namespace $SB_NAMESPACE_NAME denies public access but has no IP rules or private endpoints" \
      "Configure IP rules to allow your IP address or set up private endpoints" \
      "Current configuration prevents all access to the namespace"
  elif [[ "$https_port_result" == "failure" || "$amqp_port_result" == "failure" ]]; then
    add_issue 3 \
      "Current IP address may not be allowed to access Service Bus namespace $SB_NAMESPACE_NAME" \
      "Add your current IP address to the network rules if needed" \
      "Public network access is restricted, and your current IP may not be in the allowed list"
  fi
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 