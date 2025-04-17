#!/bin/bash

# Configuration
subscription="your-subscription-id"
resourceGroup="your-resource-group"
df_name="your-data-factory-name"
LOOKBACK_DAYS=7

# Set the subscription context
az account set --subscription "$subscription"

# Get Log Analytics workspace associated with ADF (assuming only one in the RG)
workspace_id=$(az monitor diagnostic-settings list --resource "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.DataFactory/factories/$df_name" \
    --query "[0].workspaceId" -o tsv | awk -F'/' '{print $NF}')

if [[ -z "$workspace_id" ]]; then
  echo "❌ No Log Analytics workspace found for ADF: $df_name"
  exit 1
fi

# ADF UI URL for reference
df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=$df_name"

# Repeating Failure Detection Query
kql_query=$(cat <<EOF
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "PipelineRuns"
| where status_s == "Failed"
| where Resource =~ "$df_name"
| where TimeGenerated > ago(${LOOKBACK_DAYS}d)
| summarize failure_count = count(), earliest_run = min(TimeGenerated), latest_run = max(TimeGenerated)
    by pipelineName_s, failure_message = tostring(parse_json(additionalProperties_s).FailureMessage)
| top 10 by failure_count desc
EOF
)

# Execute query
response=$(az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query "$kql_query" \
  --timespan "${LOOKBACK_DAYS}d" \
  -o json)

# Parse and build structured JSON
failed_pipelines_json="{\"failed_pipelines\":[]}"

pipelines=$(echo "$response" | jq -c '.tables[0].rows[] | {
    pipelineName_s: .[0],
    failure_message: .[1],
    failure_count: .[2],
    earliest_run: .[3],
    latest_run: .[4]
}')

while read -r pipeline; do
    pipeline_name=$(echo "$pipeline" | jq -r '.pipelineName_s')
    message=$(echo "$pipeline" | jq -r '.failure_message')
    failure_count=$(echo "$pipeline" | jq -r '.failure_count')
    earliest_run=$(echo "$pipeline" | jq -r '.earliest_run')
    latest_run=$(echo "$pipeline" | jq -r '.latest_run')

    failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
        --arg title "Repeating Failure in Pipeline \`$pipeline_name\` - Occurred $failure_count times" \
        --arg details "$message" \
        --arg severity "3" \
        --arg nextStep "Check pipeline logs for patterns around these recurring errors." \
        --arg name "$pipeline_name" \
        --arg failure_count "$failure_count" \
        --arg earliest "$earliest_run" \
        --arg latest "$latest_run" \
        --arg resource_url "$df_url" \
        '.failed_pipelines += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "name": $name,
            "failure_count": ($failure_count | tonumber),
            "earliest_failure": $earliest,
            "latest_failure": $latest,
            "resource_url": $resource_url
        }]')
done <<< "$pipelines"

# Final output
echo "$failed_pipelines_json" | jq .
