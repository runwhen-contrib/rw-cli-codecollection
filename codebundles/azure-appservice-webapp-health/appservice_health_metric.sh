#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP

# Define output files
issues_file="app_service_health_check_issues.json"
metrics_file="app_service_health_check_metrics.json"
summary_file="app_service_health_check_summary.txt"

# Use existing subscription name variable
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Initialize issues JSON - this ensures we always have valid output
issues_json='{"issues": []}'

# Get the resource ID of the App Service
if ! resource_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Found in subscription \`$SUBSCRIPTION_NAME\`" \
        --arg nextStep "Verify App Service name and resource group, or check access permissions for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "1" \
        --arg details "Could not find App Service $APP_SERVICE_NAME in resource group $AZ_RESOURCE_GROUP. Service may not exist or access may be restricted." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    
    # Generate summary for missing App Service
    echo "Health Check Summary for App Service: $APP_SERVICE_NAME" > "$summary_file"
    echo "====================================================" >> "$summary_file"
    echo "App Service State: Not Found" >> "$summary_file"
    echo "Issues Detected: 1" >> "$summary_file"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"
    
    # Save JSON outputs
    echo "$issues_json" > "$issues_file"
    echo '{"value": []}' > "$metrics_file"  # Empty metrics data
    
    echo "App Service not found. Results saved to $issues_file"
    exit 0
fi

if [[ -z "$resource_id" ]]; then
    echo "Error: Empty resource ID returned for App Service $APP_SERVICE_NAME."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Empty Resource ID for \`$APP_SERVICE_NAME\`" \
        --arg nextStep "Verify App Service \`$APP_SERVICE_NAME\` exists in resource group \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "1" \
        --arg details "App Service query returned empty resource ID. Service may not exist." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    
    # Generate summary for empty resource ID
    echo "Health Check Summary for App Service: $APP_SERVICE_NAME" > "$summary_file"
    echo "====================================================" >> "$summary_file"
    echo "App Service State: Empty Resource ID" >> "$summary_file"
    echo "Issues Detected: 1" >> "$summary_file"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"
    
    # Save JSON outputs
    echo "$issues_json" > "$issues_file"
    echo '{"value": []}' > "$metrics_file"  # Empty metrics data
    
    echo "Empty resource ID. Results saved to $issues_file"
    exit 0
fi

# Check the status of the App Service
app_service_state=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv)

if [[ "$app_service_state" != "Running" ]]; then
    echo "CRITICAL: App Service $APP_SERVICE_NAME is $app_service_state (not running)!"
    portal_url="https://portal.azure.com/#@/resource${resource_id}/overview"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` is $app_service_state (Not Running) in subscription \`$SUBSCRIPTION_NAME\`" \
        --arg nextStep "Start the App Service \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` immediately to restore service availability." \
        --arg severity "1" \
        --arg details "App Service state: $app_service_state. Service is unavailable to users. Portal URL: $portal_url" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Health Check Summary for App Service: $APP_SERVICE_NAME" > "$summary_file"
    echo "====================================================" >> "$summary_file"
    echo "App Service State: $app_service_state" >> "$summary_file"
    echo "Issues Detected: 1" >> "$summary_file"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"
    echo "Issues JSON saved at: $issues_file"
    echo "$issues_json" > "$issues_file"
    echo '{"value": []}' > "$metrics_file"  # Empty metrics data
    exit 0
fi

# Check if Health Check is configured
echo "Checking if Health Check is configured for App Service: $APP_SERVICE_NAME"
health_check_path=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "siteConfig.healthCheckPath" -o tsv)

if [[ -z "$health_check_path" || "$health_check_path" == "null" ]]; then
    echo "Health Check is not configured."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Health Check Not Configured for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`" \
        --arg nextStep "Enable Health Check for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
        --arg severity "4" \
        --arg details "Health Check is not configured for this App Service." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "Health Check is configured at path: $health_check_path"
fi

# Initialize health check data
health_check_data='{"value": []}'

# Fetch the HealthCheckStatus metric
if [[ -n "$health_check_path" && "$health_check_path" != "null" ]]; then
    echo "Fetching HealthCheckStatus for App Service: $APP_SERVICE_NAME"

    # Adjust time grain to match supported intervals for HealthCheckStatus
    time_grain="PT5M"

    if health_check_data=$(az monitor metrics list \
        --resource "$resource_id" \
        --metrics "HealthCheckStatus" \
        --interval "$time_grain" \
        --output json 2>/dev/null); then
        
        if [[ -z "$health_check_data" || $(echo "$health_check_data" | jq '.value | length') -eq 0 ]]; then
            echo "No HealthCheckStatus data found."
            issues_json=$(echo "$issues_json" | jq \
                --arg title "No Health Check Data" \
                --arg nextStep "Investigate why HealthCheckStatus data is not available for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                --arg severity "3" \
                --arg details "No data points returned for HealthCheckStatus metric." \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        else
            # Parse the HealthCheckStatus data
            total=0
            count=0
            unhealthy_count=0

            # Aggregate issues instead of logging per timestamp
            has_missing_data=false
            has_unhealthy_metrics=false

            # Read metric data using a mapfile to avoid subshell issues
            mapfile -t data_points < <(echo "$health_check_data" | jq -c ".value[].timeseries[] | .data[]")

            for data_point in "${data_points[@]}"; do
                timestamp=$(echo "$data_point" | jq -r '.timeStamp')
                value=$(echo "$data_point" | jq -r '.average')

                if [[ "$value" == "null" || -z "$value" ]]; then
                    has_missing_data=true
                    continue
                fi

                total=$(echo "$total + $value" | bc -l)
                count=$((count + 1))

                if (( $(echo "$value < 1" | bc -l) )); then
                    unhealthy_count=$((unhealthy_count + 1))
                    has_unhealthy_metrics=true
                fi
            done

            # Calculate the average health status
            if (( count > 0 )); then
                average=$(echo "$total / $count" | bc -l)
            else
                average=0
            fi

            # Generate aggregated issues
            if [ "$has_missing_data" = true ]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Missing Health Check Data" \
                    --arg nextStep "Investigate missing HealthCheckStatus data for \`$APP_SERVICE_NAME\`." \
                    --arg severity "4" \
                    --arg details "Some HealthCheckStatus data points are missing values." \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
                )
            fi

            if [ "$has_unhealthy_metrics" = true ]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Unhealthy Metrics Detected" \
                    --arg nextStep "Investigate the health of \`$APP_SERVICE_NAME\`." \
                    --arg severity "1" \
                    --arg details "$unhealthy_count metrics reported unhealthy during the queried interval." \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
                )
            fi
        fi
    else
        echo "Failed to fetch HealthCheckStatus metric."
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to Fetch Health Check Metrics" \
            --arg nextStep "Check permissions and retry metric collection for \`$APP_SERVICE_NAME\`." \
            --arg severity "3" \
            --arg details "Could not retrieve HealthCheckStatus metric from Azure Monitor." \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
fi

# Generate the health check summary
echo "Health Check Summary for App Service: $APP_SERVICE_NAME" > "$summary_file"
echo "====================================================" >> "$summary_file"
echo "App Service State: $app_service_state" >> "$summary_file"
echo "Health Check Path: ${health_check_path:-Not Configured}" >> "$summary_file"
echo "Total Data Points: ${count:-0}" >> "$summary_file"
echo "Unhealthy Data Points: ${unhealthy_count:-0}" >> "$summary_file"
echo "Average HealthCheckStatus: ${average:-N/A}" >> "$summary_file"

if (( unhealthy_count > 0 )); then
    echo "Some instances are unhealthy. Investigate the application and its dependencies." >> "$summary_file"
elif (( count == 0 )); then
    echo "No data points available during the queried interval." >> "$summary_file"
else
    echo "All instances are healthy." >> "$summary_file"
fi

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo ""
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "====================================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Always save JSON outputs
echo "$issues_json" > "$issues_file"
echo "$health_check_data" > "$metrics_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Metrics JSON saved at: $metrics_file"
echo "Issues JSON saved at: $issues_file"