#!/bin/bash

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
: "${AZURE_SUBSCRIPTION_NAME:?Must set AZURE_SUBSCRIPTION_NAME}"

# Severity levels
: "${SEVERITY_CRITICAL:=4}"    # Critical issues (e.g., failed to list Key Vaults)
: "${SEVERITY_REQUEST:=3}"     # Severity for excessive requests
: "${SEVERITY_LATENCY:=2}"     # Severity for high latency
: "${SEVERITY_LOW:=1}"         # Low severity issues

: "${REQUEST_THRESHOLD:=1}"  # Default threshold for excessive requests (requests/hour)
: "${LATENCY_THRESHOLD:=1}"    # Default threshold for high latency (milliseconds)
: "${REQUEST_INTERVAL:=PT1H}"    # Default interval for request count (1 hour)
: "${LATENCY_INTERVAL:=PT1H}"    # Default interval for latency (1 hour)
: "${TIME_RANGE:=24}"            # Default time range in hours to look back

# Calculate start and end times for the time range
start_time=$(date -u -d "$TIME_RANGE hours ago" +%Y-%m-%dT%H:%M:%SZ)
end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Create output directory if it doesn't exist
output_dir="kv_metrics"
mkdir -p "$output_dir"

# Generate timestamp for the output file
timestamp=$(date +%Y%m%d_%H%M%S)
output_file="azure_keyvault_performance_metrics.json"

# Initialize JSON output with pretty formatting
json_output='{
  "issues": []
}'

# Write initial JSON to output file
echo "$json_output" | jq '.' > "$output_file"

echo "Checking Key Vault performance metrics..."
echo "Subscription ID: $AZURE_SUBSCRIPTION_ID"
echo "Resource Group:  $AZURE_RESOURCE_GROUP"
echo "Request Threshold: $REQUEST_THRESHOLD requests/hour"
echo "Latency Threshold: $LATENCY_THRESHOLD ms"
echo "Request Interval: $REQUEST_INTERVAL"
echo "Latency Interval: $LATENCY_INTERVAL"
echo "Time Range: From $start_time to $end_time"
echo "Output will be saved to: $output_file"

# Get list of Key Vaults with comprehensive data
echo "Retrieving Key Vaults in resource group..."
if ! keyvaults_json=$(az keyvault list -g "$resource_group" --subscription "$subscription_id" --query "[].{name:name, location:location, sku:sku.name, enabledForDeployment:properties.enabledForDeployment, enabledForTemplateDeployment:properties.enabledForTemplateDeployment, enabledForDiskEncryption:properties.enabledForDiskEncryption, enabledForVolumeEncryption:properties.enabledForVolumeEncryption, tenantId:properties.tenantId, vaultUri:properties.vaultUri, id:id}" -o json 2>kv_list_err.log); then
    err_msg=$(cat kv_list_err.log)
    rm -f kv_list_err.log
    
    echo "ERROR: Could not list Key Vaults."
    cat "$output_file" | jq \
        --arg title "Failed to List Key Vaults" \
        --arg details "$err_msg" \
        --arg severity "$SEVERITY_CRITICAL" \
        --arg nextStep "Check if the resource group exists and you have the right CLI permissions." \
        --arg expected "Key Vaults should be accessible in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
        --arg actual "Failed to list Key Vaults in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
        --arg reproduceHint "az keyvault list -g \"$resource_group\" --subscription \"$subscription_id\"" \
        '.issues += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber),
           "expected": $expected,
           "actual": $actual,
           "reproduce_hint": $reproduceHint
         }]' > "$output_file.tmp" && mv "$output_file.tmp" "$output_file"
    echo "Error JSON saved to: $output_file"
    exit 1
fi
rm -f kv_list_err.log

# Check if we got any Key Vaults
if [ -z "$keyvaults_json" ] || [ "$keyvaults_json" = "[]" ]; then
    echo "No Key Vaults found in resource group."
    cat "$output_file" | jq \
        --arg title "No Key Vaults Found" \
        --arg details "No Key Vaults were found in resource group: $resource_group" \
        --arg severity "$SEVERITY_CRITICAL" \
        --arg nextStep "Verify that Key Vaults exist in the specified resource group." \
        --arg expected "Key Vaults should exist in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
        --arg actual "No Key Vaults found in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
        --arg reproduceHint "az keyvault list -g \"$resource_group\" --subscription \"$subscription_id\"" \
        '.issues += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber),
           "expected": $expected,
           "actual": $actual,
           "reproduce_hint": $reproduceHint
         }]' > "$output_file.tmp" && mv "$output_file.tmp" "$output_file"
    echo "No Key Vaults JSON saved to: $output_file"
    exit 0
fi

# Process each Key Vault
echo "$keyvaults_json" | jq -c '.[]' | while read -r kv_data; do
    # Extract Key Vault details
    kv_name=$(echo "$kv_data" | jq -r '.name')
    kv_location=$(echo "$kv_data" | jq -r '.location')
    kv_sku=$(echo "$kv_data" | jq -r '.sku')
    kv_uri=$(echo "$kv_data" | jq -r '.vaultUri')
    kv_id=$(echo "$kv_data" | jq -r '.id')
    resource_url="https://portal.azure.com/#@/resource${kv_id}/metrics"
    
    # Skip if any required field is empty
    if [ -z "$kv_name" ] || [ "$kv_name" = "null" ]; then
        echo "Warning: Skipping Key Vault with missing name"
        continue
    fi
    
    echo "Processing Key Vault: $kv_name"
    echo "Location: $kv_location"
    echo "SKU: $kv_sku"
    echo "URI: $kv_uri"
    echo "Resource URL: $resource_url"
    
    # Get request count metrics - using count aggregation with 1-hour interval to match threshold
    request_count=$(az monitor metrics list \
        --resource "/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.KeyVault/vaults/$kv_name" \
        --metric ServiceApiHit \
        --aggregation count \
        --interval "$REQUEST_INTERVAL" \
        --query "value[0].timeseries[0].data[-1].count" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --output tsv)
    
    echo "Request count for $kv_name: $request_count"
    
    # Get latency metrics - using average aggregation with 5-minute interval for granular performance monitoring
    latency=$(az monitor metrics list \
        --resource "/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.KeyVault/vaults/$kv_name" \
        --metric ServiceApiLatency \
        --aggregation average \
        --interval "$LATENCY_INTERVAL" \
        --query "value[0].timeseries[0].data[-1].average" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --output tsv)
    
    echo "Latency for $kv_name: $latency"
    
    # Default to N/A if no data is returned
    request_count=${request_count:-"N/A"}
    latency=${latency:-"N/A"}
    
    # Check for excessive requests
    if [[ "$request_count" != "N/A" && $(echo "$request_count > $REQUEST_THRESHOLD" | bc -l) -eq 1 ]]; then
        echo "Excessive requests detected for $kv_name"
        cat "$output_file" | jq \
            --arg title "Excessive Requests Detected in Key Vault \`$kv_name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg details "$keyvaults_json" \
            --arg severity "$SEVERITY_REQUEST" \
            --arg nextStep "Review Key Vault access in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg name "$kv_name" \
            --arg kv_location "$kv_location" \
            --arg kv_sku "$kv_sku" \
            --arg kv_uri "$kv_uri" \
            --arg resource_url "$resource_url" \
            --arg request_count "$request_count" \
            --arg request_threshold "$REQUEST_THRESHOLD" \
            --arg expected "Key Vault \`$kv_name\` should have request count below $REQUEST_THRESHOLD requests/hour in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg actual "Key Vault \`$kv_name\` has $request_count requests/hour (threshold: $REQUEST_THRESHOLD) in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg reproduceHint "az monitor metrics list --resource \"/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.KeyVault/vaults/$kv_name\" --metric ServiceApiHit --aggregation count --interval \"$REQUEST_INTERVAL\" --query \"value[0].timeseries[0].data[-1].count\" --start-time \"$start_time\" --end-time \"$end_time\" --output tsv" \
            '.issues += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber),
               "name": $name,
               "kv_location": $kv_location,
               "kv_sku": $kv_sku,
               "kv_uri": $kv_uri,
               "resource_url": $resource_url,
               "metric": "ServiceApiHit",
               "value": ($request_count | tonumber),
               "threshold": ($request_threshold | tonumber),
               "expected": $expected,
               "actual": $actual,
               "reproduce_hint": $reproduceHint
             }]' > "$output_file.tmp" && mv "$output_file.tmp" "$output_file"
    fi
    
    # Check for high latency
    if [[ "$latency" != "N/A" && $(echo "$latency > $LATENCY_THRESHOLD" | bc -l) -eq 1 ]]; then
        echo "High latency detected for $kv_name"
        cat "$output_file" | jq \
            --arg title "High Latency Detected in Key Vault \`$kv_name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg details "$keyvaults_json" \
            --arg severity "$SEVERITY_LATENCY" \
            --arg nextStep "Investigate network connectivity and consider implementing caching strategies to reduce latency." \
            --arg name "$kv_name" \
            --arg kv_location "$kv_location" \
            --arg kv_sku "$kv_sku" \
            --arg kv_uri "$kv_uri" \
            --arg resource_url "$resource_url" \
            --arg latency "$latency" \
            --arg latency_threshold "$LATENCY_THRESHOLD" \
            --arg expected "Key Vault \`$kv_name\` should have latency below $LATENCY_THRESHOLD ms in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg actual "Key Vault \`$kv_name\` has latency of ${latency}ms (threshold: $LATENCY_THRESHOLD) in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg reproduceHint "az monitor metrics list --resource \"/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.KeyVault/vaults/$kv_name\" --metric ServiceApiLatency --aggregation average --interval \"$LATENCY_INTERVAL\" --query \"value[0].timeseries[0].data[-1].average\" --start-time \"$start_time\" --end-time \"$end_time\" --output tsv" \
            '.issues += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber),
               "name": $name,
               "kv_location": $kv_location,
               "kv_sku": $kv_sku,
               "kv_uri": $kv_uri,
               "resource_url": $resource_url,
               "metric": "ServiceApiLatency",
               "value": ($latency | tonumber),
               "threshold": ($latency_threshold | tonumber),
               "expected": $expected,
               "actual": $actual,
               "reproduce_hint": $reproduceHint
             }]' > "$output_file.tmp" && mv "$output_file.tmp" "$output_file"
    fi
done

echo "Key Vault performance metrics check completed."
echo "Results saved to: $output_file"
echo "JSON content:"
cat "$output_file"

