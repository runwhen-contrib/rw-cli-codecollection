#!/bin/bash

# Azure Subscription Cost Health Analysis - Simplified Version
# Focus: Recommend cost savings for App Service Plans

set -euo pipefail

# Configuration
SUBSCRIPTION_IDS="${AZURE_SUBSCRIPTION_IDS:-}"
RESOURCE_GROUPS="${AZURE_RESOURCE_GROUPS:-}"
ISSUES_FILE="azure_appservice_cost_optimization_issues.json"
REPORT_FILE="azure_appservice_cost_optimization_report.txt"

# Logging function
log() {
    echo "💰 [$(date +'%H:%M:%S')] $*" >&2
}

# Get Function Apps for a given App Service Plan - OPTIMIZED VERSION
get_apps_for_plan() {
    local plan_id="$1"
    local subscription_id="$2"
    
    log "  Fetching apps for plan (optimized batch query)..."
    
    # OPTIMIZATION: Use single batch query instead of individual az resource show calls
    # This is 10-100x faster for large numbers of apps
    local all_apps=$(az resource list \
        --subscription "$subscription_id" \
        --resource-type "Microsoft.Web/sites" \
        --query "[?contains(kind, 'functionapp')].{name:name, resourceGroup:resourceGroup, serverFarmId:properties.serverFarmId, state:properties.state, kind:kind}" \
        -o json 2>/dev/null || echo '[]')
    
    # Filter to matching plan using jq
    local matching_apps=$(echo "$all_apps" | jq --arg plan_id "$plan_id" '[.[] | select(.serverFarmId == $plan_id)]')
    
    local total_apps=$(echo "$all_apps" | jq 'length')
    local matched=$(echo "$matching_apps" | jq 'length')
    
    log "  ✓ Batch query completed: found $matched apps on this plan (out of $total_apps total function apps)"
    echo "$matching_apps"
}

# Get metrics for App Service Plan - OPTIMIZED VERSION
get_plan_metrics() {
    local plan_id="$1"
    local subscription_id="$2"
    
    log "  Querying metrics (7 days, this may take 15-30 seconds)..."
    
    # Get last 7 days of metrics
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    
    # OPTIMIZATION: Query both metrics in parallel using background processes
    local cpu_metrics_file=$(mktemp)
    local memory_metrics_file=$(mktemp)
    
    # Start both queries in parallel
    (az monitor metrics list \
        --resource "$plan_id" \
        --metric "CpuPercentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average Maximum \
        --subscription "$subscription_id" \
        -o json 2>/dev/null || echo '{}') > "$cpu_metrics_file" &
    local cpu_pid=$!
    
    (az monitor metrics list \
        --resource "$plan_id" \
        --metric "MemoryPercentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average Maximum \
        --subscription "$subscription_id" \
        -o json 2>/dev/null || echo '{}') > "$memory_metrics_file" &
    local mem_pid=$!
    
    # Wait for both queries to complete
    wait $cpu_pid 2>/dev/null
    wait $mem_pid 2>/dev/null
    
    log "  ✓ Metrics queries completed"
    
    # Read results
    local cpu_metrics=$(cat "$cpu_metrics_file")
    local memory_metrics=$(cat "$memory_metrics_file")
    
    # Cleanup temp files
    rm -f "$cpu_metrics_file" "$memory_metrics_file"
    
    # Extract average and max values - convert to integers for bash comparison
    local cpu_avg=$(echo "$cpu_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print "0"}')
    local cpu_max=$(echo "$cpu_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.maximum != null) | .maximum' 2>/dev/null | sort -rn | head -1 | awk '{print int($1+0.5)}')  # Round to nearest int
    
    local mem_avg=$(echo "$memory_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print "0"}')
    local mem_max=$(echo "$memory_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.maximum != null) | .maximum' 2>/dev/null | sort -rn | head -1 | awk '{print int($1+0.5)}')  # Round to nearest int
    
    # Default to 0 if empty or invalid
    cpu_avg=${cpu_avg:-0}
    cpu_max=${cpu_max:-0}
    mem_avg=${mem_avg:-0}
    mem_max=${mem_max:-0}
    
    # Ensure they're integers (strip any remaining decimals)
    cpu_avg=$(echo "$cpu_avg" | awk '{print int($1)}')
    cpu_max=$(echo "$cpu_max" | awk '{print int($1)}')
    mem_avg=$(echo "$mem_avg" | awk '{print int($1)}')
    mem_max=$(echo "$mem_max" | awk '{print int($1)}')
    
    # Final safety check
    [[ -z "$cpu_avg" || ! "$cpu_avg" =~ ^[0-9]+$ ]] && cpu_avg=0
    [[ -z "$cpu_max" || ! "$cpu_max" =~ ^[0-9]+$ ]] && cpu_max=0
    [[ -z "$mem_avg" || ! "$mem_avg" =~ ^[0-9]+$ ]] && mem_avg=0
    [[ -z "$mem_max" || ! "$mem_max" =~ ^[0-9]+$ ]] && mem_max=0
    
    echo "$cpu_avg|$cpu_max|$mem_avg|$mem_max"
}

# Calculate App Service Plan cost
calculate_plan_cost() {
    local sku_tier="$1"
    local sku_name="$2" 
    local sku_capacity="$3"
    
    local base_cost=0
    
    # Pricing based on Azure pricing (approximate)
    case "$sku_tier" in
        "PremiumV3")
            case "$sku_name" in
                "P1v3") base_cost=146 ;;
                "P2v3") base_cost=292 ;;
                "P3v3") base_cost=584 ;;
            esac
            ;;
        "PremiumV2")
            case "$sku_name" in
                "P1v2") base_cost=146 ;;
                "P2v2") base_cost=292 ;;
                "P3v2") base_cost=584 ;;
            esac
            ;;
        "ElasticPremium")
            case "$sku_name" in
                "EP1") base_cost=146 ;;
                "EP2") base_cost=292 ;;
                "EP3") base_cost=584 ;;
            esac
            ;;
    esac
    
    echo $((base_cost * sku_capacity))
}

# Recommend rightsizing for App Service Plan based on metrics
recommend_rightsizing() {
    local current_tier="$1"
    local current_name="$2"
    local current_capacity="$3"
    local app_count="$4"
    local running_apps="$5"
    local cpu_avg="$6"
    local cpu_max="$7"
    local mem_avg="$8"
    local mem_max="$9"
    
    local recommended_capacity=$current_capacity
    local recommended_tier="$current_tier"
    local recommended_name="$current_name"
    
    # Rule 1: SKU downsizing based on CPU utilization
    # If avg CPU < 40% and max CPU < 70%, can downsize SKU
    if [[ $cpu_avg -lt 40 && $cpu_max -lt 70 ]]; then
        if [[ "$current_name" == "P3v3" ]]; then
            recommended_name="P2v3"
        elif [[ "$current_name" == "P3v2" ]]; then
            recommended_name="P2v2"
        elif [[ "$current_name" == "EP3" ]]; then
            recommended_name="EP2"
        fi
    fi
    
    # Rule 2: Further SKU downsizing if very low utilization
    # If avg CPU < 20% and max CPU < 50%, downsize more aggressively
    if [[ $cpu_avg -lt 20 && $cpu_max -lt 50 ]]; then
        if [[ "$current_name" == "P2v3" ]]; then
            recommended_name="P1v3"
        elif [[ "$current_name" == "P2v2" ]]; then
            recommended_name="P1v2"
        elif [[ "$current_name" == "EP2" ]]; then
            recommended_name="EP1"
        fi
    fi
    
    # Rule 3: Capacity reduction based on utilization and app count
    # Target: Keep max CPU under 80% after reduction
    if [[ $cpu_avg -lt 50 && $cpu_max -lt 70 ]]; then
        # Can safely reduce capacity
        local optimal_capacity=$(( (running_apps * 3) / 4 ))  # 0.75x apps
        if [[ $optimal_capacity -lt 1 ]]; then
            optimal_capacity=1
        fi
        
        if [[ $current_capacity -gt $optimal_capacity && $optimal_capacity -ge 1 ]]; then
            recommended_capacity=$optimal_capacity
        fi
    elif [[ $cpu_avg -lt 30 && $cpu_max -lt 60 ]]; then
        # Very low utilization, more aggressive reduction
        local optimal_capacity=$(( (running_apps + 1) / 2 ))  # 0.5x apps
        if [[ $optimal_capacity -lt 1 ]]; then
            optimal_capacity=1
        fi
        
        if [[ $current_capacity -gt $optimal_capacity ]]; then
            recommended_capacity=$optimal_capacity
        fi
    fi
    
    # Safety check: Don't recommend if max CPU is already high
    if [[ $cpu_max -gt 80 || $mem_max -gt 85 ]]; then
        # Already under pressure, keep current configuration
        recommended_capacity=$current_capacity
        recommended_name="$current_name"
    fi
    
    echo "$recommended_tier|$recommended_name|$recommended_capacity"
}

# Analyze App Service Plan
analyze_app_service_plan() {
    local plan_name="$1"
    local plan_id="$2"
    local resource_group="$3"
    local subscription_id="$4"
    local sku_tier="$5"
    local sku_name="$6"
    local sku_capacity="$7"
    local location="$8"
    
    log "  📋 Plan Details:"
    log "     Resource Group: $resource_group"
    log "     SKU: $sku_tier $sku_name"
    log "     Capacity: $sku_capacity instance(s)"
    log "     Location: $location"
    log ""
    
    # Get apps deployed to this plan using az resource list
    local apps=$(get_apps_for_plan "$plan_id" "$subscription_id")
    local app_count=$(echo "$apps" | jq length)
    local running_apps=$(echo "$apps" | jq '[.[] | select(.state == "Running")] | length')
    local stopped_apps=$(echo "$apps" | jq '[.[] | select(.state != "Running")] | length')
    
    log "  📱 Apps on this plan: $app_count total"
    log "     ✓ Running: $running_apps"
    log "     ✗ Stopped: $stopped_apps"
    log ""
    
    # Get performance metrics for this plan
    local metrics=$(get_plan_metrics "$plan_id" "$subscription_id")
    IFS='|' read -r cpu_avg cpu_max mem_avg mem_max <<< "$metrics"
    
    log "  📊 Performance Metrics (7 days):"
    log "     CPU: avg=${cpu_avg}%, max=${cpu_max}%"
    log "     Memory: avg=${mem_avg}%, max=${mem_max}%"
    log ""
    
    if [[ $app_count -eq 0 ]]; then
        # Empty App Service Plan
        local monthly_cost=$(calculate_plan_cost "$sku_tier" "$sku_name" "$sku_capacity")
        local annual_cost=$((monthly_cost * 12))
        
        log "🔸 Empty App Service Plan \`$plan_name\` - \$$monthly_cost/month waste"
        
        local issue=$(jq -n \
            --arg title "Empty App Service Plan \`$plan_name\`" \
            --arg description "This App Service Plan has no apps deployed" \
            --arg severity "2" \
            --arg monthly_cost "$monthly_cost" \
            --arg annual_cost "$annual_cost" \
            --arg plan_name "$plan_name" \
            --arg resource_group "$resource_group" \
            --arg subscription_id "$subscription_id" \
            --arg current_sku "$sku_tier $sku_name" \
            --arg current_capacity "$sku_capacity" \
            --arg location "$location" \
            '{
                title: $title,
                description: $description,
                severity: ($severity | tonumber),
                monthlyCost: ($monthly_cost | tonumber),
                annualCost: ($annual_cost | tonumber),
                planName: $plan_name,
                resourceGroup: $resource_group,
                subscriptionId: $subscription_id,
                currentSku: $current_sku,
                currentCapacity: ($current_capacity | tonumber),
                location: $location,
                type: "empty_plan"
            }')
        
        # Append to issues file
        if [[ -f "$ISSUES_FILE" ]]; then
            local existing_issues=$(cat "$ISSUES_FILE")
            echo "$existing_issues" | jq ". += [$issue]" > "$ISSUES_FILE"
        else
            echo "[$issue]" > "$ISSUES_FILE"
        fi
        
    else
        # Check for rightsizing opportunities based on metrics
        local rightsizing=$(recommend_rightsizing "$sku_tier" "$sku_name" "$sku_capacity" "$app_count" "$running_apps" "$cpu_avg" "$cpu_max" "$mem_avg" "$mem_max")
        IFS='|' read -r rec_tier rec_name rec_capacity <<< "$rightsizing"
        
        local current_cost=$(calculate_plan_cost "$sku_tier" "$sku_name" "$sku_capacity")
        local recommended_cost=$(calculate_plan_cost "$rec_tier" "$rec_name" "$rec_capacity")
        
        if [[ $recommended_cost -lt $current_cost ]]; then
            local monthly_savings=$((current_cost - recommended_cost))
            local annual_savings=$((monthly_savings * 12))
            
            log "💡 Rightsizing opportunity: \`$plan_name\` - \$$monthly_savings/month savings"
            log "  Current: $sku_tier $sku_name x$sku_capacity (\$$current_cost/month)"
            log "  Recommended: $rec_tier $rec_name x$rec_capacity (\$$recommended_cost/month)"
            
            local issue=$(jq -n \
                --arg title "Rightsize App Service Plan \`$plan_name\`" \
                --arg description "This App Service Plan can be downsized based on metrics analysis (CPU avg: ${cpu_avg}%, max: ${cpu_max}%)" \
                --arg severity "3" \
                --arg monthly_cost "$monthly_savings" \
                --arg annual_cost "$annual_savings" \
                --arg current_monthly_cost "$current_cost" \
                --arg recommended_monthly_cost "$recommended_cost" \
                --arg plan_name "$plan_name" \
                --arg resource_group "$resource_group" \
                --arg subscription_id "$subscription_id" \
                --arg current_sku "$sku_tier $sku_name" \
                --arg current_capacity "$sku_capacity" \
                --arg recommended_sku "$rec_tier $rec_name" \
                --arg recommended_capacity "$rec_capacity" \
                --arg app_count "$app_count" \
                --arg running_apps "$running_apps" \
                --arg cpu_avg "$cpu_avg" \
                --arg cpu_max "$cpu_max" \
                --arg mem_avg "$mem_avg" \
                --arg mem_max "$mem_max" \
                --arg location "$location" \
                '{
                    title: $title,
                    description: $description,
                    severity: ($severity | tonumber),
                    monthlyCost: ($monthly_cost | tonumber),
                    annualCost: ($annual_cost | tonumber),
                    currentMonthlyCost: ($current_monthly_cost | tonumber),
                    recommendedMonthlyCost: ($recommended_monthly_cost | tonumber),
                    planName: $plan_name,
                    resourceGroup: $resource_group,
                    subscriptionId: $subscription_id,
                    currentSku: $current_sku,
                    currentCapacity: ($current_capacity | tonumber),
                    recommendedSku: $recommended_sku,
                    recommendedCapacity: ($recommended_capacity | tonumber),
                    appCount: ($app_count | tonumber),
                    runningApps: ($running_apps | tonumber),
                    cpuAvg: ($cpu_avg | tonumber),
                    cpuMax: ($cpu_max | tonumber),
                    memAvg: ($mem_avg | tonumber),
                    memMax: ($mem_max | tonumber),
                    location: $location,
                    type: "rightsizing"
                }')
            
            # Append to issues file
            if [[ -f "$ISSUES_FILE" ]]; then
                local existing_issues=$(cat "$ISSUES_FILE")
                echo "$existing_issues" | jq ". += [$issue]" > "$ISSUES_FILE"
            else
                echo "[$issue]" > "$ISSUES_FILE"
            fi
        else
            log "  ✅ App Service Plan is appropriately sized"
        fi
    fi
    
    log ""
}

# Main function
main() {
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Azure App Service Cost Optimization Analysis                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    log "🚀 Starting analysis at $(date '+%Y-%m-%d %H:%M:%S')"
    log ""
    
    if [[ -z "$SUBSCRIPTION_IDS" ]]; then
        echo "❌ Error: AZURE_SUBSCRIPTION_IDS environment variable not set"
        exit 1
    fi
    
    # This script currently processes one subscription at a time
    # Take the first subscription from comma-separated list
    local SUBSCRIPTION_ID=$(echo "$SUBSCRIPTION_IDS" | cut -d',' -f1 | xargs)
    log "🎯 Target subscription: $SUBSCRIPTION_ID"
    log ""
    
    # If RESOURCE_GROUPS is empty, get all resource groups in the subscription
    if [[ -z "$RESOURCE_GROUPS" ]]; then
        log "🔍 No resource groups specified - discovering all resource groups..."
        RESOURCE_GROUPS=$(az group list --subscription "$SUBSCRIPTION_ID" --query "[].name" -o tsv 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        
        if [[ -z "$RESOURCE_GROUPS" ]]; then
            echo "❌ Error: No resource groups found in subscription $SUBSCRIPTION_ID"
            exit 1
        fi
        
        local rg_count=$(echo "$RESOURCE_GROUPS" | tr ',' '\n' | wc -l)
        log "✓ Found $rg_count resource groups"
    else
        local rg_count=$(echo "$RESOURCE_GROUPS" | tr ',' '\n' | wc -l)
        log "🎯 Analyzing $rg_count specified resource group(s)"
    fi
    log ""
    
    # Initialize issues file
    echo "[]" > "$ISSUES_FILE"
    
    # Process each resource group
    IFS=',' read -ra RG_ARRAY <<< "$RESOURCE_GROUPS"
    local total_rgs=${#RG_ARRAY[@]}
    local current_rg=0
    
    for rg in "${RG_ARRAY[@]}"; do
        rg=$(echo "$rg" | xargs)  # trim whitespace
        ((current_rg++))
        
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "📦 Analyzing resource group [$current_rg/$total_rgs]: $rg"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Get all App Service Plans in this resource group
        log "  Querying App Service Plans..."
        local plans=$(az appservice plan list --resource-group "$rg" --subscription "$SUBSCRIPTION_ID" \
            --query "[].{name:name, id:id, resourceGroup:resourceGroup, sku:sku, location:location}" \
            -o json 2>/dev/null || echo '[]')
        
        local plan_count=$(echo "$plans" | jq length)
        log "  ✓ Found $plan_count App Service Plan(s) in resource group: $rg"
        
        if [[ $plan_count -gt 0 ]]; then
            local plan_num=0
            echo "$plans" | jq -c '.[]' | while read -r plan; do
                ((plan_num++))
                local plan_name=$(echo "$plan" | jq -r '.name')
                local plan_id=$(echo "$plan" | jq -r '.id')
                local resource_group=$(echo "$plan" | jq -r '.resourceGroup')
                local sku_tier=$(echo "$plan" | jq -r '.sku.tier')
                local sku_name=$(echo "$plan" | jq -r '.sku.name')
                local sku_capacity=$(echo "$plan" | jq -r '.sku.capacity')
                local location=$(echo "$plan" | jq -r '.location')
                
                log ""
                log "  ┌─────────────────────────────────────────────────────────────"
                log "  │ App Service Plan [$plan_num/$plan_count]: $plan_name"
                log "  └─────────────────────────────────────────────────────────────"
                
                analyze_app_service_plan "$plan_name" "$plan_id" "$resource_group" "$SUBSCRIPTION_ID" \
                    "$sku_tier" "$sku_name" "$sku_capacity" "$location"
            done
        else
            log "  ℹ️  No App Service Plans in this resource group - skipping"
        fi
    done
    
    # Generate summary
    local total_monthly=$(jq '[.[].monthlyCost] | add // 0' "$ISSUES_FILE")
    local total_annual=$(jq '[.[].annualCost] | add // 0' "$ISSUES_FILE")
    local total_current_spend=$(jq '[.[].currentMonthlyCost] | add // 0' "$ISSUES_FILE")
    local total_recommended_spend=$(jq '[.[].recommendedMonthlyCost] | add // 0' "$ISSUES_FILE")
    local issue_count=$(jq 'length' "$ISSUES_FILE")
    
    # Calculate savings percentage
    local savings_percentage=0
    if [[ $total_current_spend -gt 0 ]]; then
        savings_percentage=$(awk "BEGIN {printf \"%.1f\", ($total_monthly / $total_current_spend) * 100}")
    fi
    
    echo ""
    log "══════════════════════════════════════════════════════════════════"
    log "✅ Analysis completed at $(date '+%Y-%m-%d %H:%M:%S')"
    log "══════════════════════════════════════════════════════════════════"
    log ""
    log "💰 COST SUMMARY:"
    log "   Current monthly spend: \$$total_current_spend (for plans with issues)"
    log "   Potential monthly savings: \$$total_monthly ($savings_percentage% reduction)"
    log "   Potential annual savings: \$$total_annual"
    log "   Optimization opportunities: $issue_count"
    log ""
    
    # Generate report
    cat > "$REPORT_FILE" << EOF
🎯 COST SAVINGS SUMMARY:
========================
💵 Current Monthly Spend: \$$total_current_spend (for resources with issues)
💰 Potential Monthly Savings: \$$total_monthly ($savings_percentage% reduction)
💰 Potential Annual Savings:  \$$total_annual
📉 Recommended Monthly Spend: \$$total_recommended_spend
📊 Issues Found: $issue_count

🔥 TOP SAVINGS OPPORTUNITIES:
$(jq -r '.[] | "   • " + .title + " - $" + (.monthlyCost | tostring) + "/month (" + ((.monthlyCost / .currentMonthlyCost * 100) | tostring | split(".")[0]) + "% savings)"' "$ISSUES_FILE")

⚡ IMMEDIATE ACTION REQUIRED:
   This analysis identified \$$total_monthly/month in potential savings ($savings_percentage% reduction)!
   Annual impact: \$$total_annual

RIGHTSIZING RECOMMENDATIONS:
$(jq -r '.[] | select(.type == "rightsizing") | "# Rightsize: " + .planName + " (Apps: " + (.runningApps | tostring) + " running)\n# Current: " + .currentSku + " x" + (.currentCapacity | tostring) + " = $" + (.currentMonthlyCost | tostring) + "/month | CPU avg: " + (.cpuAvg | tostring) + "%, max: " + (.cpuMax | tostring) + "%\n# Recommended: " + .recommendedSku + " x" + (.recommendedCapacity | tostring) + " = $" + (.recommendedMonthlyCost | tostring) + "/month | Savings: $" + (.monthlyCost | tostring) + "/month (" + ((.monthlyCost / .currentMonthlyCost * 100) | floor | tostring) + "%)\naz appservice plan update --name '\''" + .planName + "'\'' --resource-group '\''" + .resourceGroup + "'\'' --subscription '\''" + .subscriptionId + "'\'' --sku " + (.recommendedSku | split(" ")[1]) + " --number-of-workers " + (.recommendedCapacity | tostring) + "\n"' "$ISSUES_FILE")

CLEANUP COMMANDS (Empty Plans):
$(jq -r '.[] | select(.type == "empty_plan") | "# Delete: " + .planName + "\naz appservice plan delete --name '\''" + .planName + "'\'' --resource-group '\''" + .resourceGroup + "'\'' --subscription '\''" + .subscriptionId + "'\'' --yes\n"' "$ISSUES_FILE")
EOF
    
    cat "$REPORT_FILE"
}

main "$@"
