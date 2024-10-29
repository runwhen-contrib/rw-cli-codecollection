#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# VMSCALEDSET
# AZ_RESOURCE_GROUP
# OUTPUT_DIR

# Ensure OUTPUT_DIR is set
: "${OUTPUT_DIR:?OUTPUT_DIR variable is not set}"

# Log in to Azure CLI (uncomment if needed)
# az login --service-principal --username "$AZ_USERNAME" --password "$AZ_SECRET_VALUE" --tenant "$AZ_TENANT" > /dev/null
# az account set --subscription "$AZ_SUBSCRIPTION"

# Remove previous issues.json file if it exists
[ -f "$OUTPUT_DIR/issues.json" ] && rm "$OUTPUT_DIR/issues.json"

# Fetch the resource ID
resource_id=$(az vmss show --name "$VMSCALEDSET" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv)

# Display all recent activity logs in table format
echo "Azure VM Scale Set $VMSCALEDSET activity logs (recent):"
az monitor activity-log list --resource-id "$resource_id" --output table

# Initialize the JSON object to store issues only
issues_json=$(jq -n '{issues: []}')

# Define log levels with their respective severity
declare -A log_levels=( ["Critical"]="1" ["Error"]="2" ["Warning"]="4" )

# Check for each log level in activity logs and add structured issues to issues_json
for level in "${!log_levels[@]}"; do
    # Use a refined query to gather detailed log entries
    details=$(az monitor activity-log list --resource-id "$resource_id" --query "[?level=='$level']" -o json | jq -c "[.[] | {
        eventTimestamp,
        caller,
        level,
        status: .status.value,
        action: .authorization.action,
        resourceId,
        resourceGroupName,
        operationName: .operationName.localizedValue,
        resourceProvider: .resourceProviderName.localizedValue,
        message: .properties.message,
        correlationId,
        claims: {
            email: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress\",
            givenname: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname\",
            surname: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname\",
            ipaddr: .claims.ipaddr
        }
    }]")

    if [[ $(echo "$details" | jq length) -gt 0 ]]; then
        # Build the issue entry and add it to the issues array in issues_json
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$level level issues detected" \
            --arg nextStep "Check the $level-level activity logs for Azure resource \`$resource_id\` in resource group \`$AZ_RESOURCE_GROUP\`" \
            --arg severity "${log_levels[$level]}" \
            --argjson logs "$details" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $logs}]'
        )
    fi
done

# Save the structured JSON data to issues.json
echo "$issues_json" > "$OUTPUT_DIR/issues.json"
