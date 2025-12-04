#!/bin/bash

# Azure Storage Cost Optimization Analysis Script
# Analyzes storage resources to identify cost optimization opportunities
# Focuses on:
#   1) Unattached/orphaned managed disks
#   2) Old snapshots (>90 days by default)
#   3) Storage accounts without lifecycle policies
#   4) Over-provisioned redundancy (GRS/GZRS that could use LRS/ZRS)
#   5) Premium storage on low-utilization workloads

set -eo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# COST_ANALYSIS_LOOKBACK_DAYS - Days to look back for metrics (default: 30)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)
# SNAPSHOT_AGE_THRESHOLD_DAYS - Age in days for old snapshot detection (default: 90)

# Configuration
LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS:-30}
SNAPSHOT_AGE_DAYS=${SNAPSHOT_AGE_THRESHOLD_DAYS:-90}
REPORT_FILE="storage_optimization_report.txt"
ISSUES_FILE="storage_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/storage_optimization_issues_$$.json"

# Cost thresholds for severity classification
LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD:-500}
MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD:-2000}
HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD:-10000}

# Discount percentage (default to 0 if not set)
DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE:-0}

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# Cleanup function
cleanup() {
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        echo '[]' > "$ISSUES_FILE"
    fi
    rm -f "$ISSUES_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# Logging functions
log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr() { printf -- '─%.0s' {1..80} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }
progress() { printf "💾 [%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2; }

# Issue reporting function
add_issue() {
    local TITLE="$1" DETAILS="$2" SEVERITY="$3" NEXT_STEPS="$4"
    log "🔸 $TITLE (severity=$SEVERITY)"
    [[ -n "$DETAILS" ]] && log "$DETAILS"
    log "Next steps: $NEXT_STEPS"
    hr
    
    [[ $first_issue == true ]] && first_issue=false || printf "," >> "$ISSUES_TMP"
    jq -n --arg t "$TITLE" --arg d "$DETAILS" --arg n "$NEXT_STEPS" --argjson s "$SEVERITY" \
        '{title:$t,details:$d,severity:$s,next_step:$n}' >> "$ISSUES_TMP"
}

# Azure Managed Disk Pricing (monthly, USD, Central US region, LRS)
get_disk_cost() {
    local disk_sku="$1"
    local disk_size_gb="$2"
    local disk_sku_lower=$(echo "$disk_sku" | tr '[:upper:]' '[:lower:]')
    
    case "$disk_sku_lower" in
        # Premium SSD v2 - priced per GB + IOPS + throughput
        premiumv2_lrs)
            echo "scale=2; $disk_size_gb * 0.122" | bc -l
            ;;
        # Premium SSD
        premium_lrs|premium_zrs)
            if [[ $disk_size_gb -le 4 ]]; then echo "0.77"
            elif [[ $disk_size_gb -le 8 ]]; then echo "1.54"
            elif [[ $disk_size_gb -le 16 ]]; then echo "2.95"
            elif [[ $disk_size_gb -le 32 ]]; then echo "5.67"
            elif [[ $disk_size_gb -le 64 ]]; then echo "10.90"
            elif [[ $disk_size_gb -le 128 ]]; then echo "21.02"
            elif [[ $disk_size_gb -le 256 ]]; then echo "40.48"
            elif [[ $disk_size_gb -le 512 ]]; then echo "78.03"
            elif [[ $disk_size_gb -le 1024 ]]; then echo "150.34"
            elif [[ $disk_size_gb -le 2048 ]]; then echo "289.85"
            elif [[ $disk_size_gb -le 4096 ]]; then echo "558.69"
            elif [[ $disk_size_gb -le 8192 ]]; then echo "1075.84"
            elif [[ $disk_size_gb -le 16384 ]]; then echo "2071.04"
            else echo "3985.92"
            fi
            ;;
        # Standard SSD
        standardssd_lrs|standardssd_zrs)
            if [[ $disk_size_gb -le 4 ]]; then echo "0.30"
            elif [[ $disk_size_gb -le 8 ]]; then echo "0.60"
            elif [[ $disk_size_gb -le 16 ]]; then echo "1.15"
            elif [[ $disk_size_gb -le 32 ]]; then echo "2.21"
            elif [[ $disk_size_gb -le 64 ]]; then echo "4.24"
            elif [[ $disk_size_gb -le 128 ]]; then echo "8.17"
            elif [[ $disk_size_gb -le 256 ]]; then echo "15.75"
            elif [[ $disk_size_gb -le 512 ]]; then echo "30.34"
            elif [[ $disk_size_gb -le 1024 ]]; then echo "58.44"
            elif [[ $disk_size_gb -le 2048 ]]; then echo "112.61"
            elif [[ $disk_size_gb -le 4096 ]]; then echo "217.06"
            elif [[ $disk_size_gb -le 8192 ]]; then echo "418.30"
            elif [[ $disk_size_gb -le 16384 ]]; then echo "806.08"
            else echo "1553.53"
            fi
            ;;
        # Standard HDD
        standard_lrs|standard_zrs)
            if [[ $disk_size_gb -le 32 ]]; then echo "1.54"
            elif [[ $disk_size_gb -le 64 ]]; then echo "3.00"
            elif [[ $disk_size_gb -le 128 ]]; then echo "5.89"
            elif [[ $disk_size_gb -le 256 ]]; then echo "11.52"
            elif [[ $disk_size_gb -le 512 ]]; then echo "22.53"
            elif [[ $disk_size_gb -le 1024 ]]; then echo "44.06"
            elif [[ $disk_size_gb -le 2048 ]]; then echo "86.22"
            elif [[ $disk_size_gb -le 4096 ]]; then echo "168.71"
            elif [[ $disk_size_gb -le 8192 ]]; then echo "330.24"
            elif [[ $disk_size_gb -le 16384 ]]; then echo "646.68"
            else echo "1266.00"
            fi
            ;;
        # Default - estimate based on Standard SSD
        *)
            echo "scale=2; $disk_size_gb * 0.06" | bc -l
            ;;
    esac
}

# Get snapshot cost per GB per month
get_snapshot_cost_per_gb() {
    # Azure snapshots are charged at ~$0.05/GB/month for standard
    echo "0.05"
}

# Storage account redundancy costs (relative multipliers)
get_redundancy_savings() {
    local current_redundancy="$1"
    local suggested_redundancy="$2"
    
    # Approximate cost multipliers relative to LRS (1.0)
    # LRS = 1.0, ZRS = 1.25, GRS = 2.0, GZRS = 2.5, RA-GRS = 2.1, RA-GZRS = 2.6
    local current_mult=1.0
    local suggested_mult=1.0
    
    case "${current_redundancy^^}" in
        LRS) current_mult=1.0 ;;
        ZRS) current_mult=1.25 ;;
        GRS) current_mult=2.0 ;;
        GZRS) current_mult=2.5 ;;
        RAGRS|RA-GRS) current_mult=2.1 ;;
        RAGZRS|RA-GZRS) current_mult=2.6 ;;
    esac
    
    case "${suggested_redundancy^^}" in
        LRS) suggested_mult=1.0 ;;
        ZRS) suggested_mult=1.25 ;;
        GRS) suggested_mult=2.0 ;;
        GZRS) suggested_mult=2.5 ;;
        RAGRS|RA-GRS) suggested_mult=2.1 ;;
        RAGZRS|RA-GZRS) suggested_mult=2.6 ;;
    esac
    
    # Return savings percentage
    echo "scale=0; (1 - ($suggested_mult / $current_mult)) * 100" | bc -l
}

# Apply discount to cost
apply_discount() {
    local cost="$1"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        local discount_factor=$(echo "scale=4; 1 - ($DISCOUNT_PERCENTAGE / 100)" | bc -l)
        echo "scale=2; $cost * $discount_factor" | bc -l
    else
        echo "$cost"
    fi
}

# Determine severity based on monthly savings
get_severity_for_savings() {
    local monthly_savings="$1"
    local savings_int=$(printf "%.0f" "$monthly_savings")
    
    if (( savings_int >= HIGH_COST_THRESHOLD )); then
        echo "2"
    elif (( savings_int >= MEDIUM_COST_THRESHOLD )); then
        echo "3"
    elif (( savings_int >= LOW_COST_THRESHOLD )); then
        echo "4"
    else
        echo "4"
    fi
}

# Analysis 1: Find unattached managed disks
analyze_unattached_disks() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking for unattached managed disks..."
    
    local disks=$(az disk list --subscription "$subscription_id" \
        --query "[?diskState=='Unattached']" -o json 2>/dev/null || echo '[]')
    
    local disk_count=$(echo "$disks" | jq 'length')
    
    if [[ "$disk_count" -eq 0 ]]; then
        progress "  ✓ No unattached disks found"
        log "  ✓ No unattached managed disks found"
        return
    fi
    
    progress "  ⚠️  Found $disk_count unattached disk(s)"
    log "  Found $disk_count unattached managed disk(s):"
    log ""
    
    local total_savings=0
    local disk_details=""
    
    while IFS= read -r disk_data; do
        local disk_name=$(echo "$disk_data" | jq -r '.name')
        local disk_id=$(echo "$disk_data" | jq -r '.id')
        local disk_rg=$(echo "$disk_data" | jq -r '.resourceGroup')
        local disk_location=$(echo "$disk_data" | jq -r '.location')
        local disk_size_gb=$(echo "$disk_data" | jq -r '.diskSizeGb // 0')
        local disk_sku=$(echo "$disk_data" | jq -r '.sku.name // "Standard_LRS"')
        local disk_tier=$(echo "$disk_data" | jq -r '.tier // "Unknown"')
        local time_created=$(echo "$disk_data" | jq -r '.timeCreated // "Unknown"')
        
        local monthly_cost=$(get_disk_cost "$disk_sku" "$disk_size_gb")
        monthly_cost=$(apply_discount "$monthly_cost")
        total_savings=$(echo "scale=2; $total_savings + $monthly_cost" | bc -l)
        
        disk_details="${disk_details}
  • $disk_name
    - Resource Group: $disk_rg
    - Size: ${disk_size_gb} GB
    - SKU: $disk_sku
    - Created: $time_created
    - Monthly Cost: \$${monthly_cost}"
        
        log "    • $disk_name (${disk_size_gb}GB, $disk_sku) - \$${monthly_cost}/month"
    done < <(echo "$disks" | jq -c '.[]')
    
    if (( $(echo "$total_savings > 0" | bc -l) )); then
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l)
        local severity=$(get_severity_for_savings "$total_savings")
        
        local details="UNATTACHED MANAGED DISKS - WASTING COSTS:

Subscription: $subscription_name ($subscription_id)
Total Unattached Disks: $disk_count
Total Monthly Waste: \$$total_savings
Total Annual Waste: \$$annual_savings

DISK INVENTORY:
$disk_details

ISSUE:
These disks are not attached to any VM but continue to incur storage costs.
Common causes:
- VM was deleted but disk was preserved
- Snapshot restored to new disk but never attached
- Test/dev disk no longer needed

RECOMMENDATION:
Review each disk and either:
1. Attach to an existing VM if needed
2. Delete if no longer required
3. Create a snapshot before deletion if data might be needed"

        local next_steps="IMMEDIATE ACTIONS - Review and Clean Up Unattached Disks:

Azure Portal:
1. Go to 'Disks' service
2. Filter by 'Disk state' = 'Unattached'
3. Review each disk's data/purpose
4. Delete unused disks

Azure CLI - List all unattached disks:
az disk list --subscription '$subscription_id' --query \"[?diskState=='Unattached'].{Name:name, RG:resourceGroup, Size:diskSizeGb, SKU:sku.name}\" -o table

Azure CLI - Delete a specific disk:
az disk delete --name '<disk-name>' --resource-group '<resource-group>' --subscription '$subscription_id' --yes

⚠️  CAUTION: Verify disk contents before deletion. Consider creating a snapshot first if unsure."

        add_issue "Unattached Managed Disks: $disk_count disk(s) wasting \$$total_savings/month" "$details" "$severity" "$next_steps"
    fi
}

# Analysis 2: Find old snapshots
analyze_old_snapshots() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking for old snapshots (>${SNAPSHOT_AGE_DAYS} days)..."
    
    local cutoff_date=$(date -u -d "$SNAPSHOT_AGE_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    local snapshots=$(az snapshot list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
    
    # Filter old snapshots
    local old_snapshots=$(echo "$snapshots" | jq --arg cutoff "$cutoff_date" \
        '[.[] | select(.timeCreated < $cutoff)]')
    
    local snapshot_count=$(echo "$old_snapshots" | jq 'length')
    
    if [[ "$snapshot_count" -eq 0 ]]; then
        progress "  ✓ No old snapshots found"
        log "  ✓ No snapshots older than $SNAPSHOT_AGE_DAYS days"
        return
    fi
    
    progress "  ⚠️  Found $snapshot_count old snapshot(s)"
    log "  Found $snapshot_count snapshot(s) older than $SNAPSHOT_AGE_DAYS days:"
    log ""
    
    local total_size_gb=0
    local total_savings=0
    local snapshot_details=""
    local cost_per_gb=$(get_snapshot_cost_per_gb)
    
    while IFS= read -r snapshot_data; do
        local snap_name=$(echo "$snapshot_data" | jq -r '.name')
        local snap_rg=$(echo "$snapshot_data" | jq -r '.resourceGroup')
        local snap_size_gb=$(echo "$snapshot_data" | jq -r '.diskSizeGb // 0')
        local time_created=$(echo "$snapshot_data" | jq -r '.timeCreated')
        local source_disk=$(echo "$snapshot_data" | jq -r '.creationData.sourceResourceId // "Unknown"' | sed 's|.*/||')
        
        local age_days=$(( ($(date +%s) - $(date -d "$time_created" +%s)) / 86400 ))
        local monthly_cost=$(echo "scale=2; $snap_size_gb * $cost_per_gb" | bc -l)
        monthly_cost=$(apply_discount "$monthly_cost")
        
        total_size_gb=$(echo "$total_size_gb + $snap_size_gb" | bc)
        total_savings=$(echo "scale=2; $total_savings + $monthly_cost" | bc -l)
        
        snapshot_details="${snapshot_details}
  • $snap_name
    - Resource Group: $snap_rg
    - Size: ${snap_size_gb} GB
    - Age: ${age_days} days
    - Source Disk: $source_disk
    - Monthly Cost: \$${monthly_cost}"
        
        log "    • $snap_name (${snap_size_gb}GB, ${age_days} days old) - \$${monthly_cost}/month"
    done < <(echo "$old_snapshots" | jq -c '.[]')
    
    if (( $(echo "$total_savings > 0" | bc -l) )); then
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l)
        local severity=$(get_severity_for_savings "$total_savings")
        
        local details="OLD SNAPSHOTS CONSUMING STORAGE COSTS:

Subscription: $subscription_name ($subscription_id)
Total Old Snapshots: $snapshot_count
Total Size: ${total_size_gb} GB
Age Threshold: $SNAPSHOT_AGE_DAYS days
Total Monthly Cost: \$$total_savings
Total Annual Cost: \$$annual_savings

SNAPSHOT INVENTORY:
$snapshot_details

ISSUE:
These snapshots are older than $SNAPSHOT_AGE_DAYS days and may no longer be needed.
Common causes:
- One-time backup snapshots never cleaned up
- Automated snapshots without retention policy
- Pre-migration/upgrade snapshots kept 'just in case'

RECOMMENDATION:
1. Review snapshot purpose and source disk
2. Delete snapshots that are no longer needed
3. Implement automated retention policies for future snapshots"

        local next_steps="ACTIONS - Review and Clean Up Old Snapshots:

Azure Portal:
1. Go to 'Snapshots' service
2. Sort by 'Time created' (oldest first)
3. Review each snapshot's purpose
4. Delete unused snapshots

Azure CLI - List all snapshots older than ${SNAPSHOT_AGE_DAYS} days:
az snapshot list --subscription '$subscription_id' --query \"[?timeCreated<'$cutoff_date'].{Name:name, RG:resourceGroup, Size:diskSizeGb, Created:timeCreated}\" -o table

Azure CLI - Delete a specific snapshot:
az snapshot delete --name '<snapshot-name>' --resource-group '<resource-group>' --subscription '$subscription_id' --yes

BEST PRACTICE - Set up automated cleanup:
Consider using Azure Automation or Azure Policy to automatically delete snapshots older than your retention period."

        add_issue "Old Snapshots: $snapshot_count snapshot(s) (${total_size_gb}GB) costing \$$total_savings/month" "$details" "$severity" "$next_steps"
    fi
}

# Analysis 3: Check storage accounts without lifecycle policies
analyze_lifecycle_policies() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking storage accounts for lifecycle management policies..."
    
    local storage_accounts=$(az storage account list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
    local account_count=$(echo "$storage_accounts" | jq 'length')
    
    if [[ "$account_count" -eq 0 ]]; then
        progress "  ✓ No storage accounts found"
        log "  ✓ No storage accounts to analyze"
        return
    fi
    
    progress "  Found $account_count storage account(s) to analyze"
    
    local accounts_without_policy=0
    local hot_tier_accounts=0
    local account_details=""
    
    while IFS= read -r account_data; do
        local account_name=$(echo "$account_data" | jq -r '.name')
        local account_rg=$(echo "$account_data" | jq -r '.resourceGroup')
        local account_kind=$(echo "$account_data" | jq -r '.kind')
        local access_tier=$(echo "$account_data" | jq -r '.accessTier // "N/A"')
        local replication=$(echo "$account_data" | jq -r '.sku.name' | sed 's/.*_//')
        
        # Skip classic storage accounts (they don't support lifecycle management)
        if [[ "$account_kind" == "Storage" ]]; then
            continue
        fi
        
        # Check for lifecycle management policy
        local policy_exists=$(az storage account management-policy show \
            --account-name "$account_name" \
            --resource-group "$account_rg" \
            --subscription "$subscription_id" \
            -o json 2>/dev/null || echo '{"policy":null}')
        
        local has_policy=$(echo "$policy_exists" | jq -r '.policy.rules // empty | length > 0')
        
        if [[ "$has_policy" != "true" ]]; then
            accounts_without_policy=$((accounts_without_policy + 1))
            
            if [[ "$access_tier" == "Hot" ]]; then
                hot_tier_accounts=$((hot_tier_accounts + 1))
            fi
            
            account_details="${account_details}
  • $account_name
    - Resource Group: $account_rg
    - Kind: $account_kind
    - Access Tier: $access_tier
    - Replication: $replication
    - Lifecycle Policy: ❌ NOT CONFIGURED"
            
            log "    • $account_name ($account_kind, $access_tier tier) - NO lifecycle policy"
        fi
    done < <(echo "$storage_accounts" | jq -c '.[]')
    
    if [[ $accounts_without_policy -gt 0 ]]; then
        # Estimate savings based on Hot tier accounts
        # Assume 10% of data could be moved to Cool (60% cheaper) and 10% to Archive (95% cheaper)
        # This is a conservative estimate - actual savings depend on data access patterns
        
        local details="STORAGE ACCOUNTS WITHOUT LIFECYCLE MANAGEMENT:

Subscription: $subscription_name ($subscription_id)
Storage Accounts Without Policies: $accounts_without_policy
Hot Tier Accounts (highest savings potential): $hot_tier_accounts

ACCOUNTS WITHOUT LIFECYCLE POLICIES:
$account_details

ISSUE:
These storage accounts don't have lifecycle management policies configured.
Without lifecycle policies:
- All data stays in its original tier forever
- Old/inactive data continues at Hot tier pricing
- No automatic cleanup of old versions or deleted blobs

POTENTIAL SAVINGS (Tier Comparison):
- Hot → Cool: ~60% savings on storage costs
- Hot → Archive: ~95% savings on storage costs
- Example: 1TB Hot (\$20/month) → Archive (\$1/month)

RECOMMENDATION:
Configure lifecycle management policies to:
1. Move data to Cool tier after 30-90 days of no access
2. Move data to Archive tier after 180+ days
3. Delete old blob versions and soft-deleted items"

        local severity=4
        if [[ $hot_tier_accounts -ge 3 ]]; then
            severity=3
        fi
        
        local next_steps="ACTIONS - Configure Lifecycle Management Policies:

Azure Portal:
1. Go to Storage Account → Data management → Lifecycle management
2. Add rule to transition blobs to Cool tier after 30-90 days
3. Add rule to transition to Archive tier after 180+ days
4. Add rule to delete old blob versions after retention period

Azure CLI - Create a sample lifecycle policy:
cat > lifecycle-policy.json << 'EOF'
{
  \"rules\": [
    {
      \"name\": \"MoveToCoolAfter30Days\",
      \"enabled\": true,
      \"type\": \"Lifecycle\",
      \"definition\": {
        \"filters\": {\"blobTypes\": [\"blockBlob\"]},
        \"actions\": {
          \"baseBlob\": {
            \"tierToCool\": {\"daysAfterModificationGreaterThan\": 30},
            \"tierToArchive\": {\"daysAfterModificationGreaterThan\": 180}
          }
        }
      }
    }
  ]
}
EOF

az storage account management-policy create \\
  --account-name '<account-name>' \\
  --resource-group '<resource-group>' \\
  --subscription '$subscription_id' \\
  --policy @lifecycle-policy.json

⚠️  NOTE: Archive tier has retrieval costs and latency. Ensure data access patterns support archival."

        add_issue "Storage Lifecycle: $accounts_without_policy account(s) without lifecycle policies" "$details" "$severity" "$next_steps"
    else
        progress "  ✓ All storage accounts have lifecycle policies configured"
        log "  ✓ All storage accounts have lifecycle management policies"
    fi
}

# Analysis 4: Check for over-provisioned redundancy
analyze_redundancy() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking for over-provisioned storage redundancy..."
    
    local storage_accounts=$(az storage account list --subscription "$subscription_id" \
        --query "[?sku.name=='Standard_GRS' || sku.name=='Standard_RAGRS' || sku.name=='Standard_GZRS' || sku.name=='Standard_RAGZRS']" \
        -o json 2>/dev/null || echo '[]')
    
    local account_count=$(echo "$storage_accounts" | jq 'length')
    
    if [[ "$account_count" -eq 0 ]]; then
        progress "  ✓ No geo-redundant storage accounts found to review"
        log "  ✓ No geo-redundant storage accounts to review"
        return
    fi
    
    progress "  Found $account_count geo-redundant storage account(s) to review"
    log "  Found $account_count geo-redundant storage account(s):"
    log ""
    
    local account_details=""
    
    while IFS= read -r account_data; do
        local account_name=$(echo "$account_data" | jq -r '.name')
        local account_rg=$(echo "$account_data" | jq -r '.resourceGroup')
        local account_kind=$(echo "$account_data" | jq -r '.kind')
        local sku_name=$(echo "$account_data" | jq -r '.sku.name')
        local replication=$(echo "$sku_name" | sed 's/Standard_//' | sed 's/Premium_//')
        local access_tier=$(echo "$account_data" | jq -r '.accessTier // "N/A"')
        
        local savings_pct=$(get_redundancy_savings "$replication" "LRS")
        
        account_details="${account_details}
  • $account_name
    - Resource Group: $account_rg
    - Kind: $account_kind
    - Current SKU: $sku_name
    - Replication: $replication
    - Potential Savings: ~${savings_pct}% if switched to LRS"
        
        log "    • $account_name ($replication) - ~${savings_pct}% savings potential with LRS"
    done < <(echo "$storage_accounts" | jq -c '.[]')
    
    local details="GEO-REDUNDANT STORAGE ACCOUNTS - REVIEW FOR COST SAVINGS:

Subscription: $subscription_name ($subscription_id)
Geo-Redundant Accounts: $account_count

ACCOUNTS WITH GEO-REDUNDANCY:
$account_details

REDUNDANCY COST COMPARISON (relative to LRS):
- LRS (Locally Redundant): 1.0x (baseline)
- ZRS (Zone Redundant): ~1.25x
- GRS (Geo-Redundant): ~2.0x
- RA-GRS (Read-Access Geo): ~2.1x
- GZRS (Geo-Zone Redundant): ~2.5x
- RA-GZRS (Read-Access Geo-Zone): ~2.6x

EVALUATION CRITERIA:
Consider downgrading to LRS or ZRS if:
✓ Data can be recreated or restored from other sources
✓ Cross-region DR is handled at application level
✓ RPO/RTO requirements don't mandate geo-redundancy
✓ Data is for dev/test/non-critical workloads

Keep GRS/GZRS if:
✗ Regulatory compliance requires geo-redundancy
✗ Data is irreplaceable and mission-critical
✗ Business continuity requires cross-region failover"

    local severity=4
    if [[ $account_count -ge 5 ]]; then
        severity=3
    fi
    
    local next_steps="ACTIONS - Review and Optimize Storage Redundancy:

⚠️  WARNING: Changing redundancy affects data durability. Review carefully before changes.

Azure Portal:
1. Go to Storage Account → Settings → Configuration
2. Review 'Replication' setting
3. Change to LRS or ZRS if appropriate
4. Note: Some changes require data migration

Azure CLI - Check current redundancy:
az storage account list --subscription '$subscription_id' --query \"[].{Name:name, SKU:sku.name, Kind:kind}\" -o table

Azure CLI - Change to LRS (requires careful planning):
az storage account update --name '<account-name>' --resource-group '<resource-group>' --sku Standard_LRS --subscription '$subscription_id'

RECOMMENDED APPROACH:
1. Inventory all geo-redundant accounts
2. Classify by data criticality
3. Test redundancy change in non-prod first
4. Implement for dev/test accounts first
5. Document compliance requirements before changing prod"

    add_issue "Geo-Redundant Storage: $account_count account(s) - Review for potential ~50% savings" "$details" "$severity" "$next_steps"
}

# Analysis 5: Find Premium disks with low utilization
analyze_premium_disk_utilization() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking Premium disks for utilization..."
    
    # Get all Premium disks that are attached
    local premium_disks=$(az disk list --subscription "$subscription_id" \
        --query "[?sku.tier=='Premium' && diskState=='Attached']" -o json 2>/dev/null || echo '[]')
    
    local disk_count=$(echo "$premium_disks" | jq 'length')
    
    if [[ "$disk_count" -eq 0 ]]; then
        progress "  ✓ No attached Premium disks to analyze"
        log "  ✓ No attached Premium disks found"
        return
    fi
    
    progress "  Found $disk_count attached Premium disk(s) - checking IOPS utilization..."
    
    local underutilized_disks=0
    local total_savings=0
    local disk_details=""
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$LOOKBACK_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    while IFS= read -r disk_data; do
        local disk_name=$(echo "$disk_data" | jq -r '.name')
        local disk_id=$(echo "$disk_data" | jq -r '.id')
        local disk_rg=$(echo "$disk_data" | jq -r '.resourceGroup')
        local disk_size_gb=$(echo "$disk_data" | jq -r '.diskSizeGb // 0')
        local disk_sku=$(echo "$disk_data" | jq -r '.sku.name')
        local disk_iops=$(echo "$disk_data" | jq -r '.diskIOPSReadWrite // 0')
        local disk_throughput=$(echo "$disk_data" | jq -r '.diskMBpsReadWrite // 0')
        
        # Get disk metrics
        local iops_metrics=$(az monitor metrics list \
            --resource "$disk_id" \
            --metric "Composite Disk Read Operations/sec" "Composite Disk Write Operations/sec" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --interval PT1H \
            --aggregation Average Maximum \
            -o json 2>/dev/null || echo '{"value":[]}')
        
        # Calculate average and max IOPS
        local avg_read_iops=$(echo "$iops_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "0"}')
        local avg_write_iops=$(echo "$iops_metrics" | jq -r '.value[1].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "0"}')
        
        [[ -z "$avg_read_iops" || "$avg_read_iops" == "null" ]] && avg_read_iops="0"
        [[ -z "$avg_write_iops" || "$avg_write_iops" == "null" ]] && avg_write_iops="0"
        
        local total_avg_iops=$(echo "scale=0; $avg_read_iops + $avg_write_iops" | bc -l 2>/dev/null || echo "0")
        
        # Check if disk is underutilized (using less than 20% of provisioned IOPS)
        if [[ "$disk_iops" -gt 0 ]]; then
            local utilization_pct=$(echo "scale=0; ($total_avg_iops / $disk_iops) * 100" | bc -l 2>/dev/null || echo "0")
            
            if [[ "$utilization_pct" -lt 20 ]]; then
                underutilized_disks=$((underutilized_disks + 1))
                
                # Calculate savings if downgraded to Standard SSD
                local premium_cost=$(get_disk_cost "$disk_sku" "$disk_size_gb")
                local standard_cost=$(get_disk_cost "StandardSSD_LRS" "$disk_size_gb")
                local monthly_savings=$(echo "scale=2; $premium_cost - $standard_cost" | bc -l)
                monthly_savings=$(apply_discount "$monthly_savings")
                
                if (( $(echo "$monthly_savings > 0" | bc -l) )); then
                    total_savings=$(echo "scale=2; $total_savings + $monthly_savings" | bc -l)
                    
                    disk_details="${disk_details}
  • $disk_name
    - Resource Group: $disk_rg
    - Size: ${disk_size_gb} GB
    - Current SKU: $disk_sku
    - Provisioned IOPS: $disk_iops
    - Avg IOPS Used: ${total_avg_iops} (${utilization_pct}%)
    - Premium Cost: \$${premium_cost}/month
    - Standard SSD Cost: \$${standard_cost}/month
    - Potential Savings: \$${monthly_savings}/month"
                    
                    log "    • $disk_name (${disk_size_gb}GB, ${utilization_pct}% IOPS) - \$${monthly_savings}/month savings"
                fi
            fi
        fi
    done < <(echo "$premium_disks" | jq -c '.[]')
    
    if [[ $underutilized_disks -gt 0 ]] && (( $(echo "$total_savings > 0" | bc -l) )); then
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l)
        local severity=$(get_severity_for_savings "$total_savings")
        
        local details="UNDERUTILIZED PREMIUM DISKS - DOWNGRADE OPPORTUNITY:

Subscription: $subscription_name ($subscription_id)
Underutilized Premium Disks: $underutilized_disks
Total Monthly Savings: \$$total_savings
Total Annual Savings: \$$annual_savings

UNDERUTILIZED DISKS (IOPS < 20% of provisioned):
$disk_details

ISSUE:
These Premium SSD disks are using less than 20% of their provisioned IOPS.
Premium SSDs are designed for high-performance workloads.
Low utilization suggests Standard SSD would be sufficient.

COMPARISON:
- Premium SSD: High IOPS, low latency, higher cost
- Standard SSD: Moderate IOPS, good latency, lower cost
- Standard HDD: Low IOPS, higher latency, lowest cost

RECOMMENDATION:
Consider downgrading underutilized disks to Standard SSD for significant savings
while maintaining acceptable performance for low-IOPS workloads."

        local next_steps="ACTIONS - Downgrade Underutilized Premium Disks:

⚠️  WARNING: Disk SKU changes require VM to be stopped/deallocated.

Azure Portal:
1. Stop the VM using the disk
2. Go to Disk → Configuration
3. Change 'SKU' from Premium to Standard SSD
4. Start the VM

Azure CLI - Change disk SKU:
# Stop VM first
az vm deallocate --name '<vm-name>' --resource-group '<rg>' --subscription '$subscription_id'

# Update disk SKU
az disk update --name '<disk-name>' --resource-group '<rg>' --sku StandardSSD_LRS --subscription '$subscription_id'

# Start VM
az vm start --name '<vm-name>' --resource-group '<rg>' --subscription '$subscription_id'

RECOMMENDED APPROACH:
1. Test in dev/test environment first
2. Monitor disk performance after change
3. Have rollback plan ready
4. Schedule during maintenance window"

        add_issue "Underutilized Premium Disks: $underutilized_disks disk(s) - \$$total_savings/month savings" "$details" "$severity" "$next_steps"
    else
        progress "  ✓ No underutilized Premium disks found"
        log "  ✓ Premium disks appear to be appropriately utilized"
    fi
}

# Main execution
main() {
    printf "Azure Storage Cost Optimization Analysis — %s\n" "$(date -Iseconds)" > "$REPORT_FILE"
    printf "Analysis Period: Past %s days\n" "$LOOKBACK_DAYS" >> "$REPORT_FILE"
    printf "Snapshot Age Threshold: %s days\n" "$SNAPSHOT_AGE_DAYS" >> "$REPORT_FILE"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        printf "Discount Applied: %s%% off MSRP\n" "$DISCOUNT_PERCENTAGE" >> "$REPORT_FILE"
    fi
    hr
    
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Azure Storage Cost Optimization Analysis                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    progress "🚀 Starting storage optimization analysis at $(date '+%Y-%m-%d %H:%M:%S')"
    progress ""
    progress "Analysis includes:"
    progress "  • Unattached managed disks"
    progress "  • Old snapshots (>${SNAPSHOT_AGE_DAYS} days)"
    progress "  • Storage accounts without lifecycle policies"
    progress "  • Over-provisioned redundancy (GRS/GZRS)"
    progress "  • Underutilized Premium disks"
    progress ""
    
    # Parse subscription IDs
    if [[ -z "${AZURE_SUBSCRIPTION_IDS:-}" ]]; then
        AZURE_SUBSCRIPTION_IDS=$(az account show --query "id" -o tsv)
        progress "No subscription IDs specified. Using current subscription: $AZURE_SUBSCRIPTION_IDS"
    fi
    
    IFS=',' read -ra SUBSCRIPTIONS <<< "$AZURE_SUBSCRIPTION_IDS"
    local total_subscriptions=${#SUBSCRIPTIONS[@]}
    progress "Analyzing $total_subscriptions subscription(s)..."
    
    # Analyze each subscription
    local sub_index=0
    for subscription_id in "${SUBSCRIPTIONS[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)
        sub_index=$((sub_index + 1))
        
        progress ""
        progress "═══════════════════════════════════════════════════════════════════"
        progress "Subscription [$sub_index/$total_subscriptions]: $subscription_id"
        progress "═══════════════════════════════════════════════════════════════════"
        
        # Set subscription context
        az account set --subscription "$subscription_id" 2>/dev/null || {
            log "❌ Failed to set subscription context for: $subscription_id"
            progress "  ❌ Failed to access subscription"
            continue
        }
        
        local subscription_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        log ""
        log "═══════════════════════════════════════════════════════════════════"
        log "Subscription: $subscription_name ($subscription_id)"
        log "═══════════════════════════════════════════════════════════════════"
        log ""
        
        # Run all analyses
        analyze_unattached_disks "$subscription_id" "$subscription_name"
        log ""
        
        analyze_old_snapshots "$subscription_id" "$subscription_name"
        log ""
        
        analyze_lifecycle_policies "$subscription_id" "$subscription_name"
        log ""
        
        analyze_redundancy "$subscription_id" "$subscription_name"
        log ""
        
        analyze_premium_disk_utilization "$subscription_id" "$subscription_name"
        log ""
        
        hr
    done
    
    # Finalize issues JSON
    echo "]" >> "$ISSUES_TMP"
    mv "$ISSUES_TMP" "$ISSUES_FILE"
    
    # Generate summary
    local issue_count=$(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    
    log ""
    log "╔════════════════════════════════════════════════════════════════════╗"
    log "║   STORAGE ANALYSIS COMPLETE                                        ║"
    log "╚════════════════════════════════════════════════════════════════════╝"
    log ""
    log "Total Storage Optimization Issues Found: $issue_count"
    
    if [[ "$issue_count" -gt 0 ]]; then
        # Extract and display issues by category
        log ""
        log "OPTIMIZATION OPPORTUNITIES:"
        jq -r '.[] | "  • \(.title)"' "$ISSUES_FILE" 2>/dev/null || true
        
        log ""
        log "PRIORITY ACTIONS:"
        log "  1. Delete unattached disks (immediate savings)"
        log "  2. Clean up old snapshots (quick wins)"
        log "  3. Configure lifecycle policies (ongoing savings)"
        log "  4. Review redundancy settings (50% potential savings)"
        log "  5. Downgrade underutilized Premium disks"
    else
        log ""
        log "✅ No storage optimization opportunities found!"
        log "   All storage resources appear to be efficiently managed."
    fi
    
    log ""
    log "Analysis completed at $(date -Iseconds)"
    log "Report saved to: $REPORT_FILE"
    log "Issues JSON saved to: $ISSUES_FILE"
    
    progress ""
    progress "✅ Storage analysis complete!"
    progress "   Issues found: $issue_count"
    progress "   Report: $REPORT_FILE"
    progress "   Issues: $ISSUES_FILE"
}

# Run main function
main "$@"

