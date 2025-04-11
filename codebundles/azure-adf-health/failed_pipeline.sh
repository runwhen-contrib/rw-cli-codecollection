#!/bin/bash
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"

OUTPUT_FILE="failed_pipelines.json"
failed_pipelines_json='{"failed_pipelines": []}'

# KQL query to get failed pipeline runs
QUERY="
AzureDiagnostics
| where ResourceProvider == 'MICROSOFT.DATAFACTORY'
| where Category == 'PipelineRuns'
| where status_s == 'Failed'
| project ResourceId, Resource, ResourceGroup, SubscriptionId, pipelineName_s, Level, Message
"

# Execute the KQL query
echo "Retrieving failed pipeline runs..."
if ! failed_pipelines=$(az monitor log-analytics query \
    --workspace "$resource_group" \
    --analytics-query "$QUERY" \
    --subscription "$subscription_id" \
    --output json 2>pipeline_err.log); then
    err_msg=$(cat pipeline_err.log)
    rm -f pipeline_err.log
    
    echo "ERROR: Could not retrieve failed pipeline runs."
    failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
        --arg title "Failed to Retrieve Failed Pipeline Runs" \
        --arg details "$err_msg" \
        --arg severity "3" \
        --arg nextStep "Check if the resource group exists and you have the right CLI permissions." \
        '.failed_pipelines += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
    echo "$failed_pipelines_json" > "$OUTPUT_FILE"
    exit 1
fi
# rm -f pipeline_err.log

# Process each failed pipeline
for pipeline in $(echo "${failed_pipelines}" | jq -c '.[]'); do
    resource_id=$(echo $pipeline | jq -r '.ResourceId')
    resource=$(echo $pipeline | jq -r '.Resource')
    resource_group=$(echo $pipeline | jq -r '.ResourceGroup')
    subscription_id=$(echo $pipeline | jq -r '.SubscriptionId')
    pipeline_name=$(echo $pipeline | jq -r '.pipelineName_s')
    level=$(echo $pipeline | jq -r '.Level')
    message=$(echo $pipeline | jq -r '.Message')
    resource_url="https://portal.azure.com/#@/resource${resource_id}"

    failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
        --arg title "Failed Pipeline \`$pipeline_name\` in resource group \`$resource_group\` in subscription \`$subscription_id\`" \
        --arg details "$message" \
        --arg severity "3" \
        --arg nextStep "Check the pipeline configuration and logs for more details." \
        --arg name "$pipeline_name" \
        --arg resource_url "$resource_url" \
        '.failed_pipelines += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber),
           "name": $name,
           "resource_url": $resource_url
         }]')
done

# Write final JSON
echo "$failed_pipelines_json" > "$OUTPUT_FILE"
echo "Failed pipeline checks completed. Saved results to $OUTPUT_FILE"

