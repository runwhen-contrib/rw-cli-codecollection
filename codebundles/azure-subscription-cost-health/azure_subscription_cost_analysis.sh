#!/bin/bash

# Azure Subscription Cost Health Analysis - Simplified Version
# Focus: Recommend cost savings for App Service Plans

set -euo pipefail

# Configuration
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUPS="${AZURE_RESOURCE_GROUPS:-}"
ISSUES_FILE="azure_subscription_cost_analysis_issues.json"
REPORT_FILE="azure_subscription_cost_analysis_report.txt"

# Logging function
log() {
    echo "💰 [$(date +'%H:%M:%S')] $*" >&2
}

# Get Function Apps for a given App Service Plan
get_apps_for_plan() {
    local plan_id="$1"
    local subscription_id="$2"
    
    # Focus on Function Apps specifically using az functionapp list
    az functionapp list --subscription "$subscription_id" \
        --query "[?serverFarmId=='$plan_id'].{name:name, resourceGroup:resourceGroup, state:state, kind:kind}" \
        -o json 2>/dev/null || echo '[]'
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

# Recommend rightsizing for App Service Plan
recommend_rightsizing() {
    local current_tier="$1"
    local current_name="$2"
    local current_capacity="$3"
    local app_count="$4"
    local running_apps="$5"
    
    # Rightsizing logic based on app count and utilization
    local recommended_capacity=$current_capacity
    local recommended_tier="$current_tier"
    local recommended_name="$current_name"
    
    # Rule 1: If capacity > running apps + 50% buffer, recommend downsizing capacity
    local min_capacity=$(( (running_apps * 3) / 2 ))  # 1.5x running apps
    if [[ $min_capacity -lt 1 ]]; then
        min_capacity=1
    fi
    
    if [[ $current_capacity -gt $min_capacity && $current_capacity -gt 2 ]]; then
        recommended_capacity=$min_capacity
    fi
    
    # Rule 2: If very few apps relative to plan size, recommend smaller SKU
    if [[ $running_apps -le 5 && "$current_name" == "P3v3" ]]; then
        recommended_name="P2v3"
    elif [[ $running_apps -le 2 && "$current_name" == "P2v3" ]]; then
        recommended_name="P1v3"
    elif [[ $running_apps -le 5 && "$current_name" == "P3v2" ]]; then
        recommended_name="P2v2"
    elif [[ $running_apps -le 2 && "$current_name" == "P2v2" ]]; then
        recommended_name="P1v2"
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
    
    log "Analyzing App Service Plan: $plan_name"
    log "  Resource Group: $resource_group"
    log "  SKU: $sku_tier $sku_name"
    log "  Capacity: $sku_capacity instance(s)"
    log "  Location: $location"
    
    # Get apps deployed to this plan
    local apps=$(get_apps_for_plan "$plan_id" "$subscription_id")
    local app_count=$(echo "$apps" | jq length)
    local running_apps=$(echo "$apps" | jq '[.[] | select(.state == "Running")] | length')
    local stopped_apps=$(echo "$apps" | jq '[.[] | select(.state != "Running")] | length')
    
    # DEBUG: Test what az functionapp list actually returns
    local total_functionapps=$(az functionapp list --subscription "$subscription_id" --query "length(@)" -o tsv 2>/dev/null || echo "0")
    log "  DEBUG: Total Function Apps in subscription: $total_functionapps"
    
    # DEBUG: Test specific query for this plan
    local debug_apps=$(az functionapp list --subscription "$subscription_id" --query "[?serverFarmId=='$plan_id']" -o json 2>/dev/null || echo '[]')
    local debug_count=$(echo "$debug_apps" | jq length)
    log "  DEBUG: Function Apps with serverFarmId='$plan_id': $debug_count"
    
    # DEBUG: Show first few Function Apps and their serverFarmId values
    local sample_apps=$(az functionapp list --subscription "$subscription_id" --query "[0:3].{name:name, serverFarmId:serverFarmId}" -o json 2>/dev/null || echo '[]')
    log "  DEBUG: Sample Function Apps and their serverFarmId:"
    echo "$sample_apps" | jq -r '.[] | "    " + .name + " -> " + (.serverFarmId // "null")' | while read line; do
        log "$line"
    done
    
    log "  Total apps: $app_count (Running: $running_apps, Stopped: $stopped_apps)"
    
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
        # Check for rightsizing opportunities
        local rightsizing=$(recommend_rightsizing "$sku_tier" "$sku_name" "$sku_capacity" "$app_count" "$running_apps")
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
                --arg description "This App Service Plan can be downsized based on current usage" \
                --arg severity "3" \
                --arg monthly_cost "$monthly_savings" \
                --arg annual_cost "$annual_savings" \
                --arg plan_name "$plan_name" \
                --arg resource_group "$resource_group" \
                --arg subscription_id "$subscription_id" \
                --arg current_sku "$sku_tier $sku_name" \
                --arg current_capacity "$sku_capacity" \
                --arg recommended_sku "$rec_tier $rec_name" \
                --arg recommended_capacity "$rec_capacity" \
                --arg app_count "$app_count" \
                --arg running_apps "$running_apps" \
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
                    recommendedSku: $recommended_sku,
                    recommendedCapacity: ($recommended_capacity | tonumber),
                    appCount: ($app_count | tonumber),
                    runningApps: ($running_apps | tonumber),
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
    log "Starting Azure Subscription Cost Health Analysis"
    
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        echo "Error: AZURE_SUBSCRIPTION_ID environment variable not set"
        exit 1
    fi
    
    if [[ -z "$RESOURCE_GROUPS" ]]; then
        echo "Error: AZURE_RESOURCE_GROUPS environment variable not set"
        exit 1
    fi
    
    log "Target subscription: $SUBSCRIPTION_ID"
    log "Target resource groups: $RESOURCE_GROUPS"
    
    # Initialize issues file
    echo "[]" > "$ISSUES_FILE"
    
    # Process each resource group
    IFS=',' read -ra RG_ARRAY <<< "$RESOURCE_GROUPS"
    for rg in "${RG_ARRAY[@]}"; do
        rg=$(echo "$rg" | xargs)  # trim whitespace
        
        log "Analyzing resource group: $rg"
        
        # Get all App Service Plans in this resource group
        local plans=$(az appservice plan list --resource-group "$rg" --subscription "$SUBSCRIPTION_ID" \
            --query "[].{name:name, id:id, resourceGroup:resourceGroup, sku:sku, location:location}" \
            -o json 2>/dev/null || echo '[]')
        
        local plan_count=$(echo "$plans" | jq length)
        log "Found $plan_count App Service Plans in resource group: $rg"
        
        if [[ $plan_count -gt 0 ]]; then
            echo "$plans" | jq -c '.[]' | while read -r plan; do
                local plan_name=$(echo "$plan" | jq -r '.name')
                local plan_id=$(echo "$plan" | jq -r '.id')
                local resource_group=$(echo "$plan" | jq -r '.resourceGroup')
                local sku_tier=$(echo "$plan" | jq -r '.sku.tier')
                local sku_name=$(echo "$plan" | jq -r '.sku.name')
                local sku_capacity=$(echo "$plan" | jq -r '.sku.capacity')
                local location=$(echo "$plan" | jq -r '.location')
                
                analyze_app_service_plan "$plan_name" "$plan_id" "$resource_group" "$SUBSCRIPTION_ID" \
                    "$sku_tier" "$sku_name" "$sku_capacity" "$location"
            done
        fi
    done
    
    # Generate summary
    local total_monthly=$(jq '[.[].monthlyCost] | add // 0' "$ISSUES_FILE")
    local total_annual=$(jq '[.[].annualCost] | add // 0' "$ISSUES_FILE")
    local issue_count=$(jq 'length' "$ISSUES_FILE")
    
    log "Analysis completed"
    log "Total monthly savings: \$$total_monthly"
    log "Total annual savings: \$$total_annual"
    log "Issues found: $issue_count"
    
    # Generate report
    cat > "$REPORT_FILE" << EOF
🎯 COST SAVINGS SUMMARY:
========================
💰 Total Monthly Savings: \$$total_monthly
💰 Total Annual Savings:  \$$total_annual
📊 Issues Found: $issue_count

🔥 TOP SAVINGS OPPORTUNITIES:
$(jq -r '.[] | "   • " + .title + " - $" + (.monthlyCost | tostring) + "/month savings"' "$ISSUES_FILE")

⚡ IMMEDIATE ACTION REQUIRED:
   This analysis identified \$$total_monthly/month in potential savings!
   Annual impact: \$$total_annual

RIGHTSIZING RECOMMENDATIONS:
$(jq -r '.[] | select(.type == "rightsizing") | "# Rightsize: " + .planName + " (Current: " + .currentSku + " x" + (.currentCapacity | tostring) + " → Recommended: " + .recommendedSku + " x" + (.recommendedCapacity | tostring) + ")\naz appservice plan update --name '\''" + .planName + "'\'' --resource-group '\''" + .resourceGroup + "'\'' --subscription '\''" + .subscriptionId + "'\'' --sku " + (.recommendedSku | split(" ")[1]) + " --number-of-workers " + (.recommendedCapacity | tostring) + "\n"' "$ISSUES_FILE")

CLEANUP COMMANDS (Empty Plans):
$(jq -r '.[] | select(.type == "empty_plan") | "# Delete: " + .planName + "\naz appservice plan delete --name '\''" + .planName + "'\'' --resource-group '\''" + .resourceGroup + "'\'' --subscription '\''" + .subscriptionId + "'\'' --yes\n"' "$ISSUES_FILE")
EOF
    
    cat "$REPORT_FILE"
}

main "$@"
