#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP


# Get the resource ID of the App Service
resource_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv)

if [[ -z "$resource_id" ]]; then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

# Check the status of the App Service
app_service_state=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv)

if [[ "$app_service_state" != "Running" ]]; then
    echo "App Service $APP_SERVICE_NAME is not running. Health check metrics may not be reliable."
    issues_json='{"issues": []}'
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service Not Running" \
        --arg nextStep "Ensure the App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP is running before performing health checks." \
        --arg severity "2" \
        --arg details "App Service state: $app_service_state" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    summary_file="health_check_summary.txt"
    echo "Health Check Summary for App Service: $APP_SERVICE_NAME" > "$summary_file"
    echo "====================================================" >> "$summary_file"
    echo "App Service State: $app_service_state" >> "$summary_file"
    echo "Issues Detected: 1" >> "$summary_file"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"
    echo "Issues JSON saved at: issues.json"
    echo "$issues_json" > "issues.json"
    exit 0
fi

# Check if Health Check is configured
echo "Checking if Health Check is configured for App Service: $APP_SERVICE_NAME"
health_check_path=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "siteConfig.healthCheckPath" -o tsv)

issues_json='{"issues": []}'

if [[ -z "$health_check_path" || "$health_check_path" == "null" ]]; then
    echo "Health Check is not configured."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Health Check Not Configured" \
        --arg nextStep "Enable Health Check for $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP." \
        --arg severity "2" \
        --arg details "Health Check is not configured for this App Service." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "Health Check is configured at path: $health_check_path"
fi

# Fetch the HealthCheckStatus metric
if [[ -n "$health_check_path" && "$health_check_path" != "null" ]]; then
    echo "Fetching HealthCheckStatus for App Service: $APP_SERVICE_NAME"

    # Adjust time grain to match supported intervals for HealthCheckStatus
    time_grain="PT5M"

    health_check_data=$(az monitor metrics list \
        --resource "$resource_id" \
        --metrics "HealthCheckStatus" \
        --interval "$time_grain" \
        --output json)

    if [[ -z "$health_check_data" || $(echo "$health_check_data" | jq '.value | length') -eq 0 ]]; then
        echo "No HealthCheckStatus data found."
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Health Check Data" \
            --arg nextStep "Investigate why HealthCheckStatus data is not available for $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP." \
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
        has_unhealthy_instances=false

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
                has_unhealthy_instances=true
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
                --arg nextStep "Investigate missing HealthCheckStatus data for $APP_SERVICE_NAME." \
                --arg severity "4" \
                --arg details "Some HealthCheckStatus data points are missing values." \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi

        if [ "$has_unhealthy_instances" = true ]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Unhealthy Instances Detected" \
                --arg nextStep "Investigate the health of instances for $APP_SERVICE_NAME." \
                --arg severity "1" \
                --arg details "$unhealthy_count instances reported unhealthy during the queried interval." \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi
    fi
fi

# Generate the health check summary
summary_file="app_service_health_check_summary.txt"
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

# Save JSON outputs
issues_file="app_service_health_check_issues.json"
metrics_file="app_service_health_check_metrics.json"

echo "$issues_json" > "$issues_file"
echo "$health_check_data" > "$metrics_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Metrics JSON saved at: $metrics_file"
echo "Issues JSON saved at: $issues_file"