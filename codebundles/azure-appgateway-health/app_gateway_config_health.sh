#!/bin/bash

# Variables
subscription=$(az account show --query "id" -o tsv)
issues_json='{"issues": []}'
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
HEALTH_OUTPUT="${OUTPUT_DIR}/app_gateway_config_health.json"
rm -rf $HEALTH_OUTPUT || true

# Ensure required environment variables are set
if [ -z "$APP_GATEWAY_NAME" ] || [ -z "$AZ_RESOURCE_GROUP" ]; then
    echo "Error: APP_GATEWAY_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    exit 1
fi

echo "Analyzing Application Gateway $APP_GATEWAY_NAME in resource group $AZ_RESOURCE_GROUP"

# Fetch Application Gateway details
APP_GATEWAY_DETAILS=$(az network application-gateway show --name "$APP_GATEWAY_NAME" --resource-group "$AZ_RESOURCE_GROUP" -o json)

# Extract critical details
APP_GATEWAY_ID=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.id')
STATE=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.operationalState')
LOCATION=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.location')
SKU=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.sku.name')
TIER=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.sku.tier')
ENABLE_HTTP2=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.enableHttp2')
LISTENERS=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.httpListeners')
BACKEND_POOLS=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.backendAddressPools')
RULES=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.requestRoutingRules')

# Subnet Configuration
SUBNET_ID=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.gatewayIPConfigurations[0].subnet.id')
if [ "$SUBNET_ID" == "null" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Subnet Configuration" \
        --arg nextStep "Associate the Application Gateway with a valid subnet." \
        --arg severity "1" \
        --arg details "No subnet is configured for this Application Gateway." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: No subnet is configured."
else
    SUBNET_DETAILS=$(az network vnet subnet show --ids "$SUBNET_ID" -o json)
    SUBNET_NAME=$(echo "$SUBNET_DETAILS" | jq -r '.name')
    echo "Subnet: $SUBNET_NAME"
fi

# IP Configuration
IP_CONFIG=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.frontendIPConfigurations[0]')
PUBLIC_IP_ID=$(echo "$IP_CONFIG" | jq -r '.publicIPAddress.id')
PRIVATE_IP=$(echo "$IP_CONFIG" | jq -r '.privateIPAddress')
if [ "$PUBLIC_IP_ID" != "null" ]; then
    PUBLIC_IP_DETAILS=$(az network public-ip show --ids "$PUBLIC_IP_ID" -o json)
    PUBLIC_IP=$(echo "$PUBLIC_IP_DETAILS" | jq -r '.ipAddress')
    echo "Public IP: $PUBLIC_IP"
else
    echo "Private IP: $PRIVATE_IP"
fi

# SSL Certificate Check
SSL_CERTS=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.sslCertificates[]? | "\(.name): \(.expiry)"')
if [ -z "$SSL_CERTS" ]; then
    HTTPS_LISTENERS=$(echo "$LISTENERS" | jq -r '.[] | select(.protocol == "Https")')
    if [ -n "$HTTPS_LISTENERS" ]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No SSL Certificates Found" \
            --arg nextStep "Add SSL certificates for secure HTTPS communication." \
            --arg severity "1" \
            --arg details "No SSL certificates are configured, but HTTPS listeners are present." \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
        echo "Issue Detected: No SSL certificates configured for HTTPS listeners."
    else
        echo "No SSL certificates found, but no HTTPS listeners are present."
    fi
else
    echo "SSL Certificates:"
    echo "$SSL_CERTS"
fi

# WAF Configuration
WAF_CONFIG=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.webApplicationFirewallConfiguration')
if [ "$WAF_CONFIG" == "null" ]; then
    echo "Web Application Firewall is not enabled."
else
    MODE=$(echo "$WAF_CONFIG" | jq -r '.firewallMode')
    echo "WAF is enabled in $MODE mode."
fi

# Configuration Summary
echo "-------Configuration Summary--------"
echo "Application Gateway Name: $APP_GATEWAY_NAME"
echo "Location: $LOCATION"
echo "SKU: $SKU"
echo "Tier: $TIER"
echo "Operational State: $STATE"
echo "HTTP/2 Enabled: $ENABLE_HTTP2"

# Check overall operational state
if [ "$STATE" != "Running" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Application Gateway Not Running" \
        --arg nextStep "Investigate and resolve operational issues in the Azure Portal." \
        --arg severity "1" \
        --arg details "State: $STATE" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: Application Gateway is not running."
fi

# Check HTTP/2 setting
if [ "$ENABLE_HTTP2" != "true" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "HTTP/2 Disabled" \
        --arg nextStep "Enable HTTP/2 setting for better performance." \
        --arg severity "4" \
        --arg details "HTTP/2 is not enabled." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: HTTP/2 is not enabled."
fi

# Validate Listeners
echo "-------Checking Listeners--------"
if [ "$(echo "$LISTENERS" | jq length)" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Listeners Configured" \
        --arg nextStep "Configure HTTP or HTTPS listeners for the Application Gateway." \
        --arg severity "1" \
        --arg details "No listeners are configured on the Application Gateway." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: No listeners configured."
else
    echo "Listeners configured: $(echo "$LISTENERS" | jq -r '.[].name')"
fi

# Validate Backend Pools
echo "-------Checking Backend Pools--------"
if [ "$(echo "$BACKEND_POOLS" | jq length)" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Backend Pools Configured" \
        --arg nextStep "Add backend pools to route traffic to your application instances." \
        --arg severity "1" \
        --arg details "No backend pools are configured on the Application Gateway." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: No backend pools configured."
else
    for pool in $(echo "$BACKEND_POOLS" | jq -r '.[].name'); do
        echo "Checking backend pool: $pool"
        MEMBERS=$(echo "$BACKEND_POOLS" | jq --arg pool "$pool" -r '.[] | select(.name == $pool) | .backendAddresses | length')
        if [ "$MEMBERS" -eq 0 ]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Empty Backend Pool" \
                --arg nextStep "Add backend members to the pool $pool." \
                --arg severity "2" \
                --arg details "Backend pool $pool has no members." \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
            echo "Issue Detected: Backend pool $pool has no members."
        fi
    done
fi

# Validate Request Routing Rules
echo "-------Checking Request Routing Rules--------"
if [ "$(echo "$RULES" | jq length)" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Routing Rules Configured" \
        --arg nextStep "Add routing rules to define how traffic is distributed." \
        --arg severity "1" \
        --arg details "No request routing rules are configured on the Application Gateway." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: No request routing rules configured."
else
    echo "Routing rules configured: $(echo "$RULES" | jq -r '.[].name')"
fi

# Save results
echo "$issues_json" > "$HEALTH_OUTPUT"
echo "Configuration health check completed. Results saved to $HEALTH_OUTPUT"
