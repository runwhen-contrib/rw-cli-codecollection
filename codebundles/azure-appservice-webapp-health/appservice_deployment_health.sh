#!/bin/bash

# Environment variables
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

CHECK_PERIOD="${CHECK_PERIOD:-24}" # Period in hours to check for recent failed deployments

# Ensure required variables are set
if [[ -z "$APP_SERVICE_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: APP_SERVICE_NAME and AZ_RESOURCE_GROUP environment variables must be set. (detected at $log_timestamp)"
    exit 1
fi

echo "Checking deployment health for App Service '$APP_SERVICE_NAME' in resource group '$AZ_RESOURCE_GROUP'"

issues_json='{"issues": []}'

# Check deployment slots
echo "Checking deployment slots..."
DEPLOYMENTS=$(az webapp deployment slot list --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" -o json)

if [[ -z "$DEPLOYMENTS" || "$DEPLOYMENTS" == "[]" ]]; then
    echo "No deployment slots found. Checking production configuration..."
    DEPLOYMENT_CONFIG=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" -o json)

    if [[ -z "$DEPLOYMENT_CONFIG" || "$DEPLOYMENT_CONFIG" == "null" ]]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: Failed to fetch production deployment configuration. Verify the App Service and resource group. (detected at $log_timestamp)"
        exit 1
    fi

    PROD_STATE=$(echo "$DEPLOYMENT_CONFIG" | jq -r '.state // empty')

    if [[ -z "$PROD_STATE" ]]; then
        echo "Warning: Production state could not be determined."
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Production State Missing" \
            --arg nextStep "Check the App Service state in the Azure Portal." \
            --arg severity "3" \
            --arg details "Unable to fetch state for the production deployment." \
            '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]'
        )
    elif [[ "$PROD_STATE" != "Running" ]]; then
        echo "Production is in state: $PROD_STATE"
        issues_json=$(echo "$issues_json" | jq \
            --arg state "$PROD_STATE" \
            --arg title "Production Deployment Issue" \
            --arg nextStep "Investigate the production deployment in the Azure Portal." \
            --arg severity "1" \
            --arg config "$DEPLOYMENT_CONFIG" \
            '.issues += [{"title": $title, "details": "Production state: " + $state, "deployment_configuration": $config, "next_step": $nextStep, "severity": ($severity | tonumber)}]'
        )
    else
        echo "Production deployment is running."
    fi
else
    for slot in $(echo "$DEPLOYMENTS" | jq -r '.[].name'); do
        echo "Checking slot: $slot"

        SLOT_DETAILS=$(az webapp deployment slot show --name "$APP_SERVICE_NAME" --slot "$slot" --resource-group "$AZ_RESOURCE_GROUP" -o json)
        SLOT_STATE=$(echo "$SLOT_DETAILS" | jq -r '.state')

        # Debugging slot state
        echo "Slot $slot state: $SLOT_STATE"

        if [[ "$SLOT_STATE" != "Running" ]]; then
            echo "Slot $slot is in state: $SLOT_STATE"
            issues_json=$(echo "$issues_json" | jq \
                --arg slot "$slot" \
                --arg state "$SLOT_STATE" \
                --arg title "Deployment Slot Issue" \
                --arg nextStep "Investigate the issue with deployment slot '$slot' in the Azure Portal." \
                --arg severity "2" \
                --arg config "$SLOT_DETAILS" \
                '.issues += [{"title": $title, "details": "Slot state: " + $state, "slot": $slot, "deployment_configuration": $config, "next_step": $nextStep, "severity": ($severity | tonumber)}]'
            )
        fi
    done
fi

# Check deployment logs for recent failures
echo "Analyzing deployment logs..."
DEPLOYMENT_LOGS=$(az webapp log deployment show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" -o json)

if [[ -n "$DEPLOYMENT_LOGS" ]]; then
    # Identify failed deployments
    FAILED_DEPLOYMENTS=$(echo "$DEPLOYMENT_LOGS" | jq -r --argjson hours "$CHECK_PERIOD" \
        '[.[] | select(.status == "failed" and (.lastUpdatedTime | fromdateiso8601 > (now - ($hours * 3600))))]')

    if [[ "$FAILED_DEPLOYMENTS" != "[]" ]]; then
        echo "Detected recent failed deployments:"
        echo "$FAILED_DEPLOYMENTS" | jq '.'

        issues_json=$(echo "$issues_json" | jq \
            --argjson failures "$FAILED_DEPLOYMENTS" \
            --arg title "Failed Deployments" \
            --arg nextStep "Review failed deployments in the Azure Portal for further details and corrective actions." \
            --arg severity "1" \
            '.issues += [{"title": $title, "details": ($failures | tostring), "next_step": $nextStep, "severity": ($severity | tonumber)}]'
        )
    else
        echo "No failed deployments detected in the last $CHECK_PERIOD hours."
    fi

    # Identify stuck deployments
    STUCK_DEPLOYMENTS=$(echo "$DEPLOYMENT_LOGS" | jq -r --argjson hours "$CHECK_PERIOD" \
        '[.[] | select(.status == "inProgress" and (.lastUpdatedTime | fromdateiso8601 > (now - ($hours * 3600))))]')

    if [[ "$STUCK_DEPLOYMENTS" != "[]" ]]; then
        echo "Detected recent stuck deployments:"
        echo "$STUCK_DEPLOYMENTS" | jq '.'

        issues_json=$(echo "$issues_json" | jq \
            --argjson stuck "$STUCK_DEPLOYMENTS" \
            --arg title "Stuck Deployments" \
            --arg nextStep "Investigate stuck deployments in the Azure Portal and resolve issues." \
            --arg severity "2" \
            '.issues += [{"title": $title, "details": ($stuck | tostring), "next_step": $nextStep, "severity": ($severity | tonumber)}]'
        )
    else
        echo "No stuck deployments detected in the last $CHECK_PERIOD hours."
    fi
else
    echo "No deployment logs found."
fi

# Output results
echo "$issues_json" | jq '.' > "deployment_health.json"
echo "Deployment health check completed. Results saved to deployment_health.json"
