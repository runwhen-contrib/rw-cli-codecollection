#!/usr/bin/env bash

# Variables
subscription=$(az account show --query "id" -o tsv)
issues_json='{"issues": []}'
HEALTH_OUTPUT="app_gateway_config_health.json"
rm -rf "$HEALTH_OUTPUT" || true
newline=$'\n'

# Ensure required environment variables are set
if [ -z "$APP_GATEWAY_NAME" ] || [ -z "$AZ_RESOURCE_GROUP" ]; then
    echo "Error: APP_GATEWAY_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    exit 1
fi

echo "Analyzing Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`"

# Fetch Application Gateway details
APP_GATEWAY_DETAILS=$(az network application-gateway show \
    --name "$APP_GATEWAY_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    -o json)

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

# Construct a link to the Azure Portal for this Application Gateway
PORTAL_LINK="https://portal.azure.com/#@/resource${APP_GATEWAY_ID}"

# Subnet Configuration
SUBNET_ID=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.gatewayIPConfigurations[0].subnet.id')
if [ "$SUBNET_ID" == "null" ]; then
    title="Missing Subnet Configuration for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`"
    next_step="Associate Application Gateway \`$APP_GATEWAY_NAME\` with a valid subnet in Resource Group \`$AZ_RESOURCE_GROUP\`.$newline View in the Azure Portal: [$PORTAL_LINK]($PORTAL_LINK)"
    details="No subnet is configured for this Application Gateway."
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "1" \
        --arg details "$details" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]'
    )
    echo "Issue Detected: $title"
else
    SUBNET_DETAILS=$(az network vnet subnet show --ids "$SUBNET_ID" -o json)
    SUBNET_NAME=$(echo "$SUBNET_DETAILS" | jq -r '.name')
    echo "Subnet configured: $SUBNET_NAME"
fi

# IP Configuration
IP_CONFIG=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.frontendIPConfigurations[0]')
PUBLIC_IP_ID=$(echo "$IP_CONFIG" | jq -r '.publicIPAddress.id')
PRIVATE_IP=$(echo "$IP_CONFIG" | jq -r '.privateIPAddress')

if [ "$PUBLIC_IP_ID" != "null" ] && [ -n "$PUBLIC_IP_ID" ]; then
    PUBLIC_IP_DETAILS=$(az network public-ip show --ids "$PUBLIC_IP_ID" -o json)
    PUBLIC_IP=$(echo "$PUBLIC_IP_DETAILS" | jq -r '.ipAddress')
    echo "Public IP: $PUBLIC_IP"
else
    echo "Private IP: $PRIVATE_IP"
fi

# SSL Certificate Check
SSL_CERTS=$(echo "$APP_GATEWAY_DETAILS" | jq -r '.sslCertificates[]? | "\(.name): \(.expiry)"')
if [ -z "$SSL_CERTS" ]; then
    HTTPS_LISTENERS=$(echo "$LISTENERS" | jq -r '.[]? | select(.protocol == "Https")')
    if [ -n "$HTTPS_LISTENERS" ]; then
        title="No SSL Certificates Found for HTTPS Listeners on Application Gateway \`$APP_GATEWAY_NAME\`"
        next_step="Add SSL certificates for secure HTTPS communication on \`$APP_GATEWAY_NAME\`.$newline View the gateway in the [Azure Portal]($PORTAL_LINK)"
        details="No SSL certificates are configured, but HTTPS listeners are present."

        issues_json=$(echo "$issues_json" | jq \
            --arg title "$title" \
            --arg nextStep "$next_step" \
            --arg severity "1" \
            --arg details "$details" \
            '.issues += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber)
            }]'
        )
        echo "Issue Detected: $title"
    else
        echo "No SSL certificates found, but no HTTPS listeners are present."
    fi
else
    echo "SSL Certificates detected:"
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
    title="Application Gateway \`$APP_GATEWAY_NAME\` Not Running in Resource Group \`$AZ_RESOURCE_GROUP\`"
    next_step="Investigate and resolve operational issues for \`$APP_GATEWAY_NAME\` in the Azure Portal.$newline [Portal Link]($PORTAL_LINK)"
    details="State: $STATE"

    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "1" \
        --arg details "$details" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]'
    )
    echo "Issue Detected: $title"
fi

# Check HTTP/2 setting
if [ "$ENABLE_HTTP2" != "true" ]; then
    title="HTTP/2 Disabled on Application Gateway \`$APP_GATEWAY_NAME\`"
    next_step="Enable HTTP/2 on \`$APP_GATEWAY_NAME\` for better performance$newline [Portal Link]($PORTAL_LINK)"
    details="HTTP/2 is not enabled."

    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "4" \
        --arg details "$details" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]'
    )
    echo "Issue Detected: $title"
fi

# Validate Listeners
echo "-------Checking Listeners--------"
LISTENER_COUNT=$(echo "$LISTENERS" | jq '. | length')
if [ "$LISTENER_COUNT" -eq 0 ] || [ "$LISTENER_COUNT" == "null" ]; then
    title="No Listeners Configured on Application Gateway \`$APP_GATEWAY_NAME\`"
    next_step="Configure HTTP or HTTPS listeners for \`$APP_GATEWAY_NAME\`.$newline [Portal Link]($PORTAL_LINK)"
    details="No listeners are configured on the Application Gateway."

    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "1" \
        --arg details "$details" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]'
    )
    echo "Issue Detected: $title"
else
    echo "Listeners configured: $(echo "$LISTENERS" | jq -r '.[].name')"
fi

# Validate Backend Pools
echo "-------Checking Backend Pools--------"
POOL_COUNT=$(echo "$BACKEND_POOLS" | jq '. | length')
if [ "$POOL_COUNT" -eq 0 ] || [ "$POOL_COUNT" == "null" ]; then
    title="No Backend Pools Configured on Application Gateway \`$APP_GATEWAY_NAME\`"
    next_step="Add backend pools to route traffic for \`$APP_GATEWAY_NAME\`.$newline [Portal Link]($PORTAL_LINK)"
    details="No backend pools are configured on the Application Gateway."

    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "1" \
        --arg details "$details" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]'
    )
    echo "Issue Detected: $title"
else
    # Loop through each backend pool name and check membership
    for pool in $(echo "$BACKEND_POOLS" | jq -r '.[].name'); do
        echo "Checking backend pool: $pool"
        member_count=$(echo "$BACKEND_POOLS" | jq --arg pool "$pool" \
            -r '.[] | select(.name == $pool) | .backendAddresses | length')
        
        if [ "$member_count" -eq 0 ]; then
            title="Empty Backend Pool \`$pool\` on Application Gateway \`$APP_GATEWAY_NAME\`"
            next_step="Add backend members to the pool \`$pool\`.$newline [Portal Link]($PORTAL_LINK)"
            details="Backend pool \`$pool\` has no members."
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "$title" \
                --arg nextStep "$next_step" \
                --arg severity "2" \
                --arg details "$details" \
                '.issues += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "severity": ($severity | tonumber)
                }]'
            )
            echo "Issue Detected: $title"
        fi
    done
fi

# Validate Request Routing Rules
echo "-------Checking Request Routing Rules--------"
RULE_COUNT=$(echo "$RULES" | jq '. | length')
if [ "$RULE_COUNT" -eq 0 ] || [ "$RULE_COUNT" == "null" ]; then
    title="No Routing Rules Configured on Application Gateway \`$APP_GATEWAY_NAME\`"
    next_step="Add request routing rules to define how traffic is distributed for \`$APP_GATEWAY_NAME\`.$newline [Portal Link]($PORTAL_LINK)"
    details="No request routing rules are configured on the Application Gateway."

    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "1" \
        --arg details "$details" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]'
    )
    echo "Issue Detected: $title"
else
    echo "Routing rules configured: $(echo "$RULES" | jq -r '.[].name')"
fi

# Save results
echo "$issues_json" > "$HEALTH_OUTPUT"
echo "Configuration health check completed. Results saved to \`$HEALTH_OUTPUT\`"
