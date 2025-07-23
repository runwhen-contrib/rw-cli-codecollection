#!/bin/bash

# Default configuration
DEFAULT_OFFSET="24h"  # Default to 24 hour lookback

# Threshold configuration (percentage)
CPU_THRESHOLD=${CPU_THRESHOLD:-80}
MEMORY_THRESHOLD=${MEMORY_THRESHOLD:-80}
DISK_QUEUE_THRESHOLD=${DISK_QUEUE_THRESHOLD:-10}

# Recommendation thresholds
SCALE_UP_CPU_THRESHOLD=${SCALE_UP_CPU_THRESHOLD:-70}
SCALE_UP_MEMORY_THRESHOLD=${SCALE_UP_MEMORY_THRESHOLD:-70}
SCALE_DOWN_CPU_THRESHOLD=${SCALE_DOWN_CPU_THRESHOLD:-30}
SCALE_DOWN_MEMORY_THRESHOLD=${SCALE_DOWN_MEMORY_THRESHOLD:-30}

# Time range parameters
METRICS_OFFSET=${METRICS_OFFSET:-$DEFAULT_OFFSET}
METRICS_INTERVAL=${METRICS_INTERVAL:-PT1H}  # Default to 1 hour interval

# Output files
OUTPUT_JSON="asp_metrics.json"
HIGH_USAGE_JSON="asp_high_usage_metrics.json"
RECOMMENDATIONS_JSON="asp_recommendations.json"

# Initialize JSON output
echo '[]' > "$OUTPUT_JSON"
echo '[]' > "$HIGH_USAGE_JSON"
echo '[]' > "$RECOMMENDATIONS_JSON"

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Azure CLI is not installed. Please install it first: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check if user is logged in to Azure
if ! az account show &> /dev/null; then
    echo "Please log in to Azure using 'az login'"
    exit 1
fi

# Get all app service plans
app_service_plans=$(az appservice plan list --query "[].{name:name, resourceGroup:resourceGroup, sku:sku.name, tier:sku.tier, capacity:sku.capacity, location:location}" -o json)

# Check if any app service plans were found
if [ -z "$app_service_plans" ] || [ "$app_service_plans" = "[]" ]; then
    echo "No App Service Plans found in your Azure subscription."
    exit 0
fi

# Print time range information
echo "Metrics will be collected for the last $METRICS_OFFSET with interval $METRICS_INTERVAL"
echo "To customize, set METRICS_OFFSET and/or METRICS_INTERVAL environment variables"
echo "Example: METRICS_OFFSET='24h' METRICS_INTERVAL='PT1H' $0"
echo ""

# Print header
echo "Checking App Service Plan Capacity..."
echo "----------------------------------------------------"
echo ""

# Function to add data to JSON file
add_to_json() {
    local file=$1
    local data=$2
    
    if [ -s "$file" ] && [ "$(jq 'length' "$file" 2>/dev/null || echo '0')" -gt 0 ]; then
        jq --argjson newData "$data" '. + [$newData]' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        echo "[$data]" > "$file"
    fi

    # Check for invalid JSON
    if ! jq empty "$file" 2>/dev/null; then
        echo "Invalid JSON detected in $file"
        exit 1
    fi
}

# Function to get tier recommendations
get_tier_recommendations() {
    local current_tier=$1
    local cpu_usage=$2
    local memory_usage=$3
    local disk_queue=$4
    
    local recommendations=()
    local reasons=()
    
    # Check if we need to scale up
    if [ ! -z "$cpu_usage" ] && (( $(echo "$cpu_usage > $SCALE_UP_CPU_THRESHOLD" | bc -l) )); then
        reasons+=("High CPU usage: ${cpu_usage}%")
    fi
    
    if [ ! -z "$memory_usage" ] && (( $(echo "$memory_usage > $SCALE_UP_MEMORY_THRESHOLD" | bc -l) )); then
        reasons+=("High Memory usage: ${memory_usage}%")
    fi
    
    if [ ! -z "$disk_queue" ] && (( $(echo "$disk_queue > $DISK_QUEUE_THRESHOLD" | bc -l) )); then
        reasons+=("High Disk Queue Length: ${disk_queue}")
    fi
    
    # Check if we need to scale down
    local scale_down_reasons=()
    if [ ! -z "$cpu_usage" ] && (( $(echo "$cpu_usage < $SCALE_DOWN_CPU_THRESHOLD" | bc -l) )); then
        scale_down_reasons+=("Low CPU usage: ${cpu_usage}%")
    fi
    
    if [ ! -z "$memory_usage" ] && (( $(echo "$memory_usage < $SCALE_DOWN_MEMORY_THRESHOLD" | bc -l) )); then
        scale_down_reasons+=("Low Memory usage: ${memory_usage}%")
    fi
    
    # Generate recommendations based on current tier
    case $current_tier in
        "Free"|"Shared"|"Basic")
            if [ ${#reasons[@]} -gt 0 ]; then
                recommendations+=("Consider upgrading to Standard tier for better performance and features")
                recommendations+=("Standard tier provides dedicated instances and better scaling capabilities")
            fi
            ;;
        "Standard")
            if [ ${#reasons[@]} -gt 0 ]; then
                recommendations+=("Consider upgrading to Premium tier for enhanced performance")
                recommendations+=("Premium tier offers better CPU and memory allocation")
            elif [ ${#scale_down_reasons[@]} -gt 0 ]; then
                recommendations+=("Consider downgrading to Basic tier to reduce costs")
                recommendations+=("Current usage suggests Basic tier may be sufficient")
            fi
            ;;
        "Premium")
            if [ ${#reasons[@]} -gt 0 ]; then
                recommendations+=("Consider increasing instance count (capacity) for better performance")
                recommendations+=("Premium tier is already optimal, focus on capacity scaling")
            elif [ ${#scale_down_reasons[@]} -gt 0 ]; then
                recommendations+=("Consider downgrading to Standard tier to reduce costs")
                recommendations+=("Current usage suggests Standard tier may be sufficient")
            fi
            ;;
        "Isolated")
            if [ ${#reasons[@]} -gt 0 ]; then
                recommendations+=("Consider increasing instance count (capacity) for better performance")
                recommendations+=("Isolated tier is already optimal, focus on capacity scaling")
            elif [ ${#scale_down_reasons[@]} -gt 0 ]; then
                recommendations+=("Consider downgrading to Premium tier to reduce costs")
                recommendations+=("Current usage suggests Premium tier may be sufficient")
            fi
            ;;
    esac
    
    # If no specific recommendations, provide general guidance
    if [ ${#recommendations[@]} -eq 0 ]; then
        if [ ${#reasons[@]} -gt 0 ]; then
            recommendations+=("Monitor usage patterns and consider scaling up if high usage persists")
        elif [ ${#scale_down_reasons[@]} -gt 0 ]; then
            recommendations+=("Consider cost optimization by scaling down if low usage continues")
        else
            recommendations+=("Current usage is within optimal range")
        fi
    fi
    
    # Return recommendations as a single string with newlines
    printf '%s\n' "${recommendations[@]}"
}

# Function to get capacity recommendations
get_capacity_recommendations() {
    local current_capacity=$1
    local cpu_usage=$2
    local memory_usage=$3
    local disk_queue=$4
    
    local recommendations=()
    local reasons=()
    
    # Check if we need to scale up capacity
    if [ ! -z "$cpu_usage" ] && (( $(echo "$cpu_usage > $SCALE_UP_CPU_THRESHOLD" | bc -l) )); then
        reasons+=("High CPU usage: ${cpu_usage}%")
    fi
    
    if [ ! -z "$memory_usage" ] && (( $(echo "$memory_usage > $SCALE_UP_MEMORY_THRESHOLD" | bc -l) )); then
        reasons+=("High Memory usage: ${memory_usage}%")
    fi
    
    if [ ! -z "$disk_queue" ] && (( $(echo "$disk_queue > $DISK_QUEUE_THRESHOLD" | bc -l) )); then
        reasons+=("High Disk Queue Length: ${disk_queue}")
    fi
    
    # Check if we need to scale down capacity
    local scale_down_reasons=()
    if [ ! -z "$cpu_usage" ] && (( $(echo "$cpu_usage < $SCALE_DOWN_CPU_THRESHOLD" | bc -l) )); then
        scale_down_reasons+=("Low CPU usage: ${cpu_usage}%")
    fi
    
    if [ ! -z "$memory_usage" ] && (( $(echo "$memory_usage < $SCALE_DOWN_MEMORY_THRESHOLD" | bc -l) )); then
        scale_down_reasons+=("Low Memory usage: ${memory_usage}%")
    fi
    
    # Generate capacity recommendations
    if [ ${#reasons[@]} -gt 0 ]; then
        local suggested_capacity=$((current_capacity + 1))
        recommendations+=("Consider increasing capacity from $current_capacity to $suggested_capacity instances")
    elif [ ${#scale_down_reasons[@]} -gt 0 ] && [ $current_capacity -gt 1 ]; then
        local suggested_capacity=$((current_capacity - 1))
        recommendations+=("Consider decreasing capacity from $current_capacity to $suggested_capacity instances")
    else
        recommendations+=("Current capacity appears optimal for the usage patterns")
    fi
    
    # Return recommendations as a single string with newlines
    printf '%s\n' "${recommendations[@]}"
}

# Process each app service plan
echo "$app_service_plans" | jq -c '.[]' | while read -r plan; do
    name=$(echo "$plan" | jq -r '.name')
    rg=$(echo "$plan" | jq -r '.resourceGroup')
    sku=$(echo "$plan" | jq -r '.sku')
    tier=$(echo "$plan" | jq -r '.tier')
    capacity=$(echo "$plan" | jq -r '.capacity')
    location=$(echo "$plan" | jq -r '.location')
    
    # Get metrics for the app service plan with the specified time range
    metrics=$(az monitor metrics list \
        --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.Web/serverfarms/$name" \
        --metric "CpuPercentage" "MemoryPercentage" "DiskQueueLength" \
        --offset "$METRICS_OFFSET" \
        --interval "$METRICS_INTERVAL" \
        --query "value[].timeseries[0].data[0].average" \
        -o tsv 2>/dev/null || echo "")
    
    # If no metrics found, try to get the most recent data point with a fixed 24h lookback
    if [ -z "$metrics" ] || [ "$(echo "$metrics" | wc -l)" -lt 3 ]; then
        echo "⚠️  No metrics found for the specified time range. Trying to get the most recent data point..."
        metrics=$(az monitor metrics list \
            --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.Web/serverfarms/$name" \
            --metric "CpuPercentage" "MemoryPercentage" "DiskQueueLength" \
            --interval "PT1H" \
            --offset "24h" \
            --query "value[].timeseries[0].data[-1].average" \
            -o tsv 2>/dev/null || echo "")
    fi
    # Format metrics to one decimal place, or empty string if missing
    cpu_usage_raw=$(echo "$metrics" | awk 'NR==1')
    memory_usage_raw=$(echo "$metrics" | awk 'NR==2')
    disk_queue_raw=$(echo "$metrics" | awk 'NR==3')
    cpu_usage=""
    memory_usage=""
    disk_queue=""
    if [ -n "$cpu_usage_raw" ]; then
        cpu_usage=$(printf "%.1f" "$cpu_usage_raw" 2>/dev/null || echo "")
    fi
    if [ -n "$memory_usage_raw" ]; then
        memory_usage=$(printf "%.1f" "$memory_usage_raw" 2>/dev/null || echo "")
    fi
    if [ -n "$disk_queue_raw" ]; then
        disk_queue=$(printf "%.1f" "$disk_queue_raw" 2>/dev/null || echo "")
    fi
    # Calculate available capacity
    available_cpu=""
    available_memory=""
    if [ -n "$cpu_usage" ]; then
        available_cpu=$(awk -v cpu="$cpu_usage" 'BEGIN { printf "%.1f", 100 - cpu }')
    fi
    if [ -n "$memory_usage" ]; then
        available_memory=$(awk -v mem="$memory_usage" 'BEGIN { printf "%.1f", 100 - mem }')
    fi
    
    # Print plan details
    echo "App Service Plan: $name"
    echo "Resource Group: $rg"
    echo "Location: $location"
    echo "SKU: $sku ($tier)"
    echo "Instance Capacity: $capacity"
    echo "Current CPU Usage: ${cpu_usage:-N/A}% (${available_cpu:-N/A}% available)"
    echo "Current Memory Usage: ${memory_usage:-N/A}% (${available_memory:-N/A}% available)"
    echo "Disk Queue Length: ${disk_queue:-N/A}"
    
    # Get recommendations
    tier_recommendations=$(get_tier_recommendations "$tier" "$cpu_usage" "$memory_usage" "$disk_queue")
    capacity_recommendations=$(get_capacity_recommendations "$capacity" "$cpu_usage" "$memory_usage" "$disk_queue")
    
    # Print recommendations
    echo ""
    echo "📊 RECOMMENDATIONS:"
    echo "Tier Recommendations:"
    if [ ! -z "$tier_recommendations" ]; then
        echo "$tier_recommendations" | while read -r rec; do
            if [ ! -z "$rec" ]; then
                echo "  • $rec"
            fi
        done
    else
        echo "  • No tier changes recommended at this time"
    fi
    
    echo ""
    echo "Capacity Recommendations:"
    if [ ! -z "$capacity_recommendations" ]; then
        echo "$capacity_recommendations" | while read -r rec; do
            if [ ! -z "$rec" ]; then
                echo "  • $rec"
            fi
        done
    else
        echo "  • No capacity changes recommended at this time"
    fi
    
    # Prepare JSON output
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create JSON object for current metrics
    subscription_id=$(az account show --query id -o tsv)
    resource_link="https://portal.azure.com/#@/resource/subscriptions/${subscription_id}/resourceGroups/${rg}/providers/Microsoft.Web/serverfarms/${name}/overview"
    
    json_data=$(jq -n \
        --arg name "$name" \
        --arg rg "$rg" \
        --arg location "$location" \
        --arg sku "$sku" \
        --arg tier "$tier" \
        --arg capacity "$capacity" \
        --arg cpu_usage "$cpu_usage" \
        --arg memory_usage "$memory_usage" \
        --arg disk_queue "$disk_queue" \
        --arg available_cpu "$available_cpu" \
        --arg available_memory "$available_memory" \
        --arg timestamp "$timestamp" \
        --arg resource_link "$resource_link" \
        '{
            name: $name,
            resourceGroup: $rg,
            location: $location,
            sku: $sku,
            tier: $tier,
            capacity: $capacity,
            metrics: {
                cpu: {
                    usage: $cpu_usage,
                    available: $available_cpu,
                    unit: "%"
                },
                memory: {
                    usage: $memory_usage,
                    available: $available_memory,
                    unit: "%"
                },
                disk: {
                    queueLength: $disk_queue
                }
            },
            timestamp: $timestamp,
            resourceLink: $resource_link
        }')
    
    # Add to main output
    add_to_json "$OUTPUT_JSON" "$json_data"
    
    # Check for high usage and add to high usage JSON if needed
    high_usage=false
    high_usage_reasons=()
    
    if [ ! -z "$cpu_usage" ] && (( $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) )); then
        high_usage=true
        high_usage_reasons+=("CPU usage ${cpu_usage}% > ${CPU_THRESHOLD}%")
        echo "⚠️  WARNING: High CPU usage detected! (${cpu_usage}% > ${CPU_THRESHOLD}%)"
    fi
    
    if [ ! -z "$memory_usage" ] && (( $(echo "$memory_usage > $MEMORY_THRESHOLD" | bc -l) )); then
        high_usage=true
        high_usage_reasons+=("Memory usage ${memory_usage}% > ${MEMORY_THRESHOLD}%")
        echo "⚠️  WARNING: High Memory usage detected! (${memory_usage}% > ${MEMORY_THRESHOLD}%)"
    fi
    
    if [ ! -z "$disk_queue" ] && (( $(echo "$disk_queue > $DISK_QUEUE_THRESHOLD" | bc -l) )); then
        high_usage=true
        high_usage_reasons+=("Disk queue length ${disk_queue} > ${DISK_QUEUE_THRESHOLD}")
        echo "⚠️  WARNING: High Disk Queue Length detected! (${disk_queue} > ${DISK_QUEUE_THRESHOLD})"
    fi
    
    # If high usage, add to high usage JSON
    if [ "$high_usage" = true ]; then
        # Convert reasons array to JSON array
        reasons_json=$(printf '%s\n' "${high_usage_reasons[@]}" | jq -R . | jq -s .)
        
        # Add reasons to the JSON data
        high_usage_data=$(echo "$json_data" | jq --argjson reasons "$reasons_json" '. + {highUsageReasons: $reasons}')
        
        add_to_json "$HIGH_USAGE_JSON" "$high_usage_data"
    fi
    
    # Create recommendations JSON
    # Convert recommendations to proper JSON arrays with complete sentences
    tier_recs_json=$(echo "$tier_recommendations" | grep -v '^$' | jq -R . | jq -s .)
    capacity_recs_json=$(echo "$capacity_recommendations" | grep -v '^$' | jq -R . | jq -s .)
    
    recommendations_data=$(jq -n \
        --arg name "$name" \
        --arg rg "$rg" \
        --arg tier "$tier" \
        --arg capacity "$capacity" \
        --arg cpu_usage "$cpu_usage" \
        --arg memory_usage "$memory_usage" \
        --arg disk_queue "$disk_queue" \
        --argjson tier_recommendations "$tier_recs_json" \
        --argjson capacity_recommendations "$capacity_recs_json" \
        --arg timestamp "$timestamp" \
        --arg resource_link "$resource_link" \
        '{
            name: $name,
            resourceGroup: $rg,
            currentTier: $tier,
            currentCapacity: $capacity,
            metrics: {
                cpu: $cpu_usage,
                memory: $memory_usage,
                diskQueue: $disk_queue
            },
            recommendations: {
                tier: $tier_recommendations,
                capacity: $capacity_recommendations
            },
            timestamp: $timestamp,
            resourceLink: $resource_link
        }')
    
    add_to_json "$RECOMMENDATIONS_JSON" "$recommendations_data"
    
    echo "----------------------------------------------------"
    echo ""
done

# Print summary
echo ""
echo "----------------------------------------------------"
echo "Summary:"
echo "- Full metrics saved to: $OUTPUT_JSON"
echo "- High usage metrics saved to: $HIGH_USAGE_JSON"
echo "- Recommendations saved to: $RECOMMENDATIONS_JSON"
echo "- Thresholds used: CPU=${CPU_THRESHOLD}%, Memory=${MEMORY_THRESHOLD}%, Disk Queue=${DISK_QUEUE_THRESHOLD}"
echo "- Scale up thresholds: CPU=${SCALE_UP_CPU_THRESHOLD}%, Memory=${SCALE_UP_MEMORY_THRESHOLD}%"
echo "- Scale down thresholds: CPU=${SCALE_DOWN_CPU_THRESHOLD}%, Memory=${SCALE_DOWN_MEMORY_THRESHOLD}%"
echo "----------------------------------------------------"
