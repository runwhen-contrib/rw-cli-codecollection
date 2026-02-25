#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_RESOURCE_GROUP
#   AZURE_RESOURCE_SUBSCRIPTION_ID
#   THRESHOLD_MB - Threshold in MB for heavy read/write operations
# -----------------------------------------------------------------------------

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"
: "${THRESHOLD_MB:?Must set THRESHOLD_MB}"

THRESHOLD_BYTES=$(echo "$THRESHOLD_MB * 1024 * 1024" | bc)
THRESHOLD_BYTES=${THRESHOLD_BYTES%.*}
echo "Threshold: $THRESHOLD_MB MB ($THRESHOLD_BYTES bytes)"

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="data_volume_audit.json"
audit_json='{"data_volume_alerts": []}'

# Function to validate JSON
validate_json() {
    local json_data="$1"
    if [[ -z "$json_data" ]]; then
        echo "Empty JSON data" >&2
        return 1
    fi
    if ! echo "$json_data" | jq empty 2>/dev/null; then
        echo "Invalid JSON format" >&2
        return 1
    fi
    return 0
}

# Function to safely extract JSON field
safe_jq() {
    local json_data="$1"
    local filter="$2"
    local default="${3:-}"
    
    if validate_json "$json_data"; then
        echo "$json_data" | jq -r "$filter" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
    if [[ -z "$subscription" ]]; then
        echo "ERROR: Could not determine current subscription ID and AZURE_RESOURCE_SUBSCRIPTION_ID is not set."
        echo "$audit_json" > "$output_file"
        exit 1
    fi
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
if ! az account set --subscription "$subscription" 2>/dev/null; then
    echo "ERROR: Failed to set subscription to $subscription"
    echo "$audit_json" > "$output_file"
    exit 1
fi

echo "Checking Data Factories for heavy data operations..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"
echo "Threshold: $THRESHOLD_MB MB"

# Configure Azure CLI to explicitly allow or disallow preview extensions
echo "Configuring Azure CLI extensions..."
if ! az config set extension.dynamic_install_allow_preview=true 2>/dev/null; then
    echo "WARNING: Could not configure Azure CLI extension settings"
fi

# Check and install datafactory extension if needed
echo "Checking for datafactory extension..."
if ! az extension show --name datafactory >/dev/null 2>&1; then
    echo "Installing datafactory extension..."
    if ! az extension add --name datafactory 2>/dev/null; then
        echo "ERROR: Failed to install datafactory extension."
        echo "$audit_json" > "$output_file"
        exit 1
    fi
fi

# Get all Data Factories in the resource group
echo "Fetching Data Factories..."
if ! datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json 2>/dev/null); then
    echo "ERROR: Failed to list Data Factories in resource group $resource_group"
    echo "$audit_json" > "$output_file"
    exit 1
fi

if ! validate_json "$datafactories"; then
    echo "ERROR: Invalid JSON response from Data Factory list command"
    audit_json=$(echo "$audit_json" | jq \
        --arg title "Invalid JSON from datafactory list" \
        --arg details "Raw output: $datafactories" \
        --arg severity "4" \
        --arg nextStep "Check Azure CLI output and permissions." \
        --arg expected "Valid JSON output from datafactory list" \
        --arg actual "Invalid JSON output from datafactory list" \
        '.data_volume_alerts += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "expected": $expected,
            "actual": $actual,
            "severity": ($severity | tonumber)
        }]')
    echo "$audit_json" > "$output_file"
    exit 1
fi

if [[ "$datafactories" == "[]" ]] || [[ -z "$datafactories" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$audit_json" > "$output_file"
    exit 0
fi

while IFS= read -r row; do
    if [[ -z "$row" ]] || ! validate_json "$row"; then
        echo "Skipping invalid Data Factory entry"
        continue
    fi
    
    df_name=$(safe_jq "$row" '.name' "unknown")
    df_id=$(safe_jq "$row" '.id' "")
    df_rg=$(safe_jq "$row" '.resourceGroup' "$resource_group")
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"

    if [[ -z "$df_id" ]] || [[ "$df_name" == "unknown" ]]; then
        echo "Skipping Data Factory with missing required fields"
        continue
    fi

    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings with better error handling
    diagnostics=""
    if ! diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log); then
        err_msg="Failed to get diagnostic settings"
        if [[ -f diag_err.log ]]; then
            err_msg=$(cat diag_err.log 2>/dev/null || echo "$err_msg")
        fi
        rm -f diag_err.log

        audit_json=$(echo "$audit_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics" \
            --arg expected "Diagnostic settings should be enabled" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            --arg actual "Diagnostic settings not enabled" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f diag_err.log

    if ! validate_json "$diagnostics" || [[ "$diagnostics" == "[]" ]]; then
        audit_json=$(echo "$audit_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name" \
            --arg details "No diagnostic settings configured or invalid response" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics" \
            --arg expected "Diagnostic settings should be enabled" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            --arg actual "Diagnostic settings not enabled" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    # Extract Log Analytics workspace ID
    workspace_id=$(safe_jq "$diagnostics" '.[0].workspaceId // empty' "")

    # Count how many ActivityRuns logs are enabled
    enabled_activity_runs_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length' "0")

    if [[ "$enabled_activity_runs_count" -eq 0 ]]; then
        audit_json=$(echo "$audit_json" | jq \
            --arg title "ActivityRuns Logging Disabled in Data Factory $df_name" \
            --arg details "ActivityRuns logging category is required for data volume monitoring" \
            --arg severity "4" \
            --arg nextStep "Enable ActivityRuns logging in diagnostic settings" \
            --arg expected "ActivityRuns logging should be enabled" \
            --arg resource_url "$df_url" \
            --arg actual "ActivityRuns logging is disabled" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" --subscription \"$subscription_id\" --output json" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    if [[ -z "$workspace_id" ]] || [[ "$workspace_id" == "null" ]]; then
        audit_json=$(echo "$audit_json" | jq \
            --arg title "No Log Analytics Workspace for $df_name" \
            --arg details "Diagnostics are configured but no workspace is defined" \
            --arg severity "4" \
            --arg nextStep "Configure Log Analytics workspace" \
            --arg expected "Log Analytics workspace should be configured" \
            --arg resource_url "$df_url" \
            --arg actual "No Log Analytics workspace configured" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    # Get customer ID (GUID) for the workspace
    workspace_guid=""
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg="Failed to get workspace GUID"
        if [[ -f guid_err.log ]]; then
            err_msg=$(cat guid_err.log 2>/dev/null || echo "$err_msg")
        fi
        rm -f guid_err.log

        audit_json=$(echo "$audit_json" | jq \
            --arg title "Failed to get Log Analytics workspace GUID for $df_name in resource group \`$resource_group\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify workspace permissions" \
            --arg expected "Should be able to query workspace information" \
            --arg resource_url "$df_url" \
            --arg actual "Failed to get workspace GUID" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f guid_err.log

    if [[ -z "$workspace_guid" ]]; then
        audit_json=$(echo "$audit_json" | jq \
            --arg title "Empty workspace GUID for $df_name in resource group \`$resource_group\`" \
            --arg details "Workspace GUID is empty or null" \
            --arg severity "4" \
            --arg nextStep "Verify workspace configuration" \
            --arg expected "Should have valid workspace GUID" \
            --arg resource_url "$df_url" \
            --arg actual "Empty workspace GUID" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    # KQL Query to check for heavy data operations
    kql_query=$(cat <<EOF
let threshold = $THRESHOLD_BYTES;
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "ActivityRuns"
| where status_s == "Succeeded"
| where Resource =~ "$df_name"
| top 1 by TimeGenerated desc
| extend isHeavyRead = toint(Output_dataRead_d > threshold), isHeavyWrite = toint(Output_dataWritten_d > threshold)
| project TimeGenerated, pipelineName_s, pipelineRunId_g, Output_dataRead_d, Output_dataWritten_d, isHeavyRead, isHeavyWrite, ResourceId
EOF
)

    echo "Querying data volume metrics for $df_name..."
    volume_data=""
    if ! volume_data=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>volume_query_err.log); then
        err_msg="Log Analytics query failed"
        if [[ -f volume_query_err.log ]]; then
            err_msg=$(cat volume_query_err.log 2>/dev/null || echo "$err_msg")
        fi
        rm -f volume_query_err.log
        
        audit_json=$(echo "$audit_json" | jq \
            --arg title "Log Analytics Query Failed for $df_name" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data" \
            --arg expected "Log Analytics query should be successful" \
            --arg resource_url "$df_url" \
            --arg actual "Log Analytics query failed" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f volume_query_err.log

    if ! validate_json "$volume_data"; then
        echo "Warning: Invalid JSON in volume_data for $df_name, skipping..."
        audit_json=$(echo "$audit_json" | jq \
            --arg title "Invalid JSON from log-analytics query for $df_name" \
            --arg details "Raw output: $volume_data" \
            --arg severity "4" \
            --arg nextStep "Check Azure CLI output and permissions." \
            --arg expected "Valid JSON output from log-analytics query" \
            --arg actual "Invalid JSON output from log-analytics query" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber)
            }]')
        continue
    fi

    # Process volume data if valid
    while IFS= read -r activity; do
        if [[ -z "$activity" ]] || ! validate_json "$activity"; then
            continue
        fi
        
        pipeline_name=$(safe_jq "$activity" '.pipelineName_s' "unknown")
        run_id=$(safe_jq "$activity" '.pipelineRunId_g' "unknown")
        data_read=$(safe_jq "$activity" '.Output_dataRead_d' "0")
        data_written=$(safe_jq "$activity" '.Output_dataWritten_d' "0")
        is_heavy_read=$(safe_jq "$activity" '.isHeavyRead' "0")
        is_heavy_write=$(safe_jq "$activity" '.isHeavyWrite' "0")
        observed_at=$(safe_jq "$activity" '.TimeGenerated' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")

        if [[ "$is_heavy_read" -eq 1 ]] || [[ "$is_heavy_write" -eq 1 ]]; then
            audit_json=$(echo "$audit_json" | jq \
                --arg title "Large Data Operation Detected in Pipeline \`$pipeline_name\` in resource group \`$resource_group\`" \
                --arg details "$activity" \
                --arg severity "4" \
                --arg nextStep "Review and adjust ADF Integration Runtime configuration in resource group \`$resource_group\`" \
                --arg name "$pipeline_name" \
                --arg expected "ADF pipeline \`$pipeline_name\` data operations should be below ${THRESHOLD_MB}MB threshold in resource group \`$resource_group\`" \
                --arg actual "ADF pipeline \`$pipeline_name\` has large data operations in resource group \`$resource_group\`" \
                --arg resource_url "$df_url" \
                --arg run_id "$run_id" \
                --arg observed_at "$observed_at" \
                --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
                '.data_volume_alerts += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "actual": $actual,
                    "severity": ($severity | tonumber),
                    "name": $name,
                    "resource_url": $resource_url,
                    "expected": $expected,
                    "reproduce_hint": $reproduce_hint,
                    "run_id": $run_id,
                    "observed_at": $observed_at
                }]')
        fi
    done < <(echo "$volume_data" | jq -c '.[]' 2>/dev/null || echo "")
done < <(echo "$datafactories" | jq -c '.[]' 2>/dev/null || echo "")

# Write output to file
echo "Final JSON contents:"
if validate_json "$audit_json"; then
    echo "$audit_json" | jq . 2>/dev/null || echo "$audit_json"
else
    echo "Warning: Final JSON is invalid, using fallback"
    audit_json='{"data_volume_alerts": []}'
fi
echo "$audit_json" > "$output_file"
echo "Data volume audit completed. Results saved to $output_file"