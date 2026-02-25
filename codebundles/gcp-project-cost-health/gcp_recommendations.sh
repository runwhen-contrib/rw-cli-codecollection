#!/bin/bash

# GCP Cost Optimization Recommendations
# Fetches recommendations from GCP Recommender API for cost optimization

set -euo pipefail

# Environment variables
PROJECT_IDS="${GCP_PROJECT_IDS:-}"
LOOKBACK_DAYS="${COST_ANALYSIS_LOOKBACK_DAYS:-30}"
REPORT_FILE="${REPORT_FILE:-gcp_recommendations.txt}"
ISSUES_FILE="${ISSUES_FILE:-gcp_recommendations_issues.json}"

# Logging function
log() {
    echo "💰 [$(date '+%H:%M:%S')] $*" >&2
}

# Initialize issues JSON
echo '[]' > "$ISSUES_FILE"

# Recommendation types for COST optimization ONLY
# Excludes security/IAM, logging, and monitoring recommendations
RECOMMENDATION_TYPES=(
    "google.compute.instance.MachineTypeRecommender"          # Rightsizing compute instances
    "google.compute.instance.IdleResourceRecommender"         # Idle/unused instances
    "google.compute.instance.StopRecommender"                 # Stopped instances that can be deleted
    "google.compute.instance.UsageCommitmentRecommender"      # Resource-based CUDs (N2/E2 cores/memory)
    "google.compute.commitment.UsageOptimizationRecommender"  # Commitment optimization
    "google.compute.commitment.UsageCommitmentRecommender"    # Committed use discounts
    "google.compute.disk.IdleResourceRecommender"             # Idle/unused disks
    "google.compute.disk.DeleteRecommender"                   # Disks that can be deleted
    "google.cloudsql.instance.IdleRecommender"                # Idle Cloud SQL instances
    "google.cloudsql.instance.OverprovisionedRecommender"     # Overprovisioned Cloud SQL
    "google.cloudsql.instance.OutOfDiskRecommender"           # Cloud SQL disk optimization
    "google.billing.commitment.UsageBasedDiscountRecommender" # Usage-based commitment recommendations
    "google.billing.commitment.SpendBasedCommitmentRecommender" # Flexible/Spend-based CUDs (FinOps Hub)
)

# Function to list available recommenders for a project
list_available_recommenders() {
    local project_id="$1"
    log "Listing available recommenders for project: $project_id"
    gcloud recommender recommenders list --project="$project_id" --format="value(name)" 2>/dev/null || echo ""
}

# Function to get recommendations for a project
get_recommendations_for_project() {
    local project_id="$1"
    local recommender_type="$2"
    
    log "Fetching recommendations for project: $project_id, type: $recommender_type"
    
    # Extract the location/zone from recommender type if needed
    local location="global"
    if [[ "$recommender_type" == *"compute"* || "$recommender_type" == *"billing"* ]]; then
        # For CUD/commitment recommenders, check key regions where recommendations typically exist
        # For other recommenders, global is sufficient
        if [[ "$recommender_type" == *"commitment"* || "$recommender_type" == *"Commitment"* ]]; then
            # CUD recommendations are region-specific
            # Get active regions for this project (where resources exist)
            local active_regions=$(gcloud compute instances list --project="$project_id" --format="value(zone)" 2>/dev/null | sed 's/-[a-z]$//' | sort -u | head -10)
            
            if [[ -z "$active_regions" ]]; then
                # No compute instances found, check top US/EU regions as fallback
                local locations=("us-central1" "us-east1" "europe-west1")
            else
                # Use actual regions where resources exist
                local locations=()
                while IFS= read -r region; do
                    [[ -n "$region" ]] && locations+=("$region")
                done <<< "$active_regions"
            fi
        else
            local locations=("global")
        fi
        
        for loc in "${locations[@]}"; do
            local recommendations=$(timeout 10 gcloud recommender recommendations list \
                --project="$project_id" \
                --recommender="$recommender_type" \
                --location="$loc" \
                --format=json \
                2>&1)
            
            local exit_code=$?
            if [[ $exit_code -ne 0 ]]; then
                # Log error but continue
                if [[ $exit_code -eq 124 ]]; then
                    log "  ⚠️  Timeout checking location $loc"
                else
                    log "  ⚠️  Error checking location $loc: $(echo "$recommendations" | head -1)"
                fi
                continue
            fi
            
            # Filter for ACTIVE recommendations (but don't fail if filter doesn't work)
            local active_recommendations=$(echo "$recommendations" | jq '[.[] | select(.stateInfo.state == "ACTIVE" or .stateInfo.state == null)]' 2>/dev/null || echo "$recommendations")
            
            if [[ "$active_recommendations" != "[]" && -n "$active_recommendations" && "$active_recommendations" != "null" ]]; then
                local count=$(echo "$active_recommendations" | jq 'length' 2>/dev/null || echo "0")
                if [[ "$count" -gt 0 ]]; then
                    log "  ✅ Found $count recommendation(s) in location $loc"
                    echo "$active_recommendations" | jq --arg proj "$project_id" --arg loc "$loc" --arg type "$recommender_type" '[.[] | {
                            projectId: $proj,
                            location: $loc,
                            recommenderType: $type,
                            name: .name,
                            description: .description,
                            primaryImpact: .primaryImpact,
                            state: (.stateInfo.state // "ACTIVE"),
                            priority: .priority,
                            content: .content
                        }]'
                fi
            fi
        done
    else
        # For non-compute recommenders, use global location
        local recommendations=$(timeout 10 gcloud recommender recommendations list \
            --project="$project_id" \
            --recommender="$recommender_type" \
            --location="global" \
            --format=json \
            2>&1)
        
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            if [[ $exit_code -eq 124 ]]; then
                log "  ⚠️  Timeout"
            else
                log "  ⚠️  Error: $(echo "$recommendations" | head -1)"
            fi
            return
        fi
        
        # Filter for ACTIVE recommendations
        local active_recommendations=$(echo "$recommendations" | jq '[.[] | select(.stateInfo.state == "ACTIVE" or .stateInfo.state == null)]' 2>/dev/null || echo "$recommendations")
        
        if [[ "$active_recommendations" != "[]" && -n "$active_recommendations" && "$active_recommendations" != "null" ]]; then
            local count=$(echo "$active_recommendations" | jq 'length' 2>/dev/null || echo "0")
            if [[ "$count" -gt 0 ]]; then
                log "  ✅ Found $count recommendation(s)"
                echo "$active_recommendations" | jq --arg proj "$project_id" --arg type "$recommender_type" '[.[] | {
                        projectId: $proj,
                        location: "global",
                        recommenderType: $type,
                        name: .name,
                        description: .description,
                        primaryImpact: .primaryImpact,
                        state: (.stateInfo.state // "ACTIVE"),
                        priority: .priority,
                        content: .content
                    }]'
            fi
        fi
    fi
}

# Function to format cost impact
format_cost_impact() {
    local impact_json="$1"
    echo "$impact_json" | jq -r '
        if .costProjection then
            "Estimated savings: $" + (.costProjection.cost.currencyCode // "USD") + " " + 
            ((.costProjection.cost.units // 0 | tostring) + "." + 
            ((.costProjection.cost.nanos // 0) / 1000000000 | tostring | .[2:4]))
        else
            "Cost impact: " + (.category // "Unknown")
        end
    ' 2>/dev/null || echo "Cost impact: Unknown"
}

# Function to determine severity from priority
get_severity() {
    local priority="$1"
    case "$priority" in
        "P1"|"P2")
            echo "2"
            ;;
        "P3")
            echo "3"
            ;;
        *)
            echo "4"
            ;;
    esac
}

# Function to get billing account recommendations
get_billing_account_recommendations() {
    log "Checking billing account level recommendations..."
    
    # Check if billing API is accessible
    local billing_check=$(gcloud billing accounts list --format=json 2>&1)
    local billing_exit=$?
    
    if [[ $billing_exit -ne 0 ]]; then
        log "  ⚠️  Cannot access billing accounts"
        log "     Error: $(echo "$billing_check" | head -3 | tr '\n' ' ')"
        log "     This may be due to:"
        log "     - Billing API not enabled (enable with: gcloud services enable cloudbilling.googleapis.com)"
        log "     - Insufficient permissions (need 'billing.accounts.list' permission)"
        log "     - Service account doesn't have billing account access"
        echo "[]"
        return
    fi
    
    # Get billing accounts
    local billing_accounts=$(echo "$billing_check" | jq -r '.[].name' 2>/dev/null || echo "")
    local billing_account_count=$(echo "$billing_check" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ -z "$billing_accounts" || "$billing_account_count" -eq 0 ]]; then
        log "  ℹ️  No billing accounts found (this is normal if using organization-level billing)"
        echo "[]"
        return
    fi
    
    log "  Found $billing_account_count billing account(s):"
    echo "$billing_check" | jq -r '.[] | "    - " + .name + " (" + .displayName + ")"' 2>/dev/null >&2 || echo "$billing_accounts" >&2
    
    local all_billing_recs="[]"
    
    while IFS= read -r billing_account; do
        [[ -z "$billing_account" ]] && continue
        
        # Extract just the account ID (format is usually "billingAccounts/XXXXX-XXXXX-XXXXX")
        local account_id=$(echo "$billing_account" | sed 's|.*/||')
        log "  Checking billing account: $account_id"
        
        # Check for billing-level recommenders (including FinOps Hub CUD types)
        for recommender_type in \
            "google.billing.commitment.UsageBasedDiscountRecommender" \
            "google.billing.commitment.SpendBasedCommitmentRecommender" \
            "google.compute.commitment.UsageOptimizationRecommender" \
            "google.compute.commitment.UsageCommitmentRecommender"; do
            log "    Checking recommender: $recommender_type"
            local recommendations=$(timeout 10 gcloud recommender recommendations list \
                --billing-account="$account_id" \
                --recommender="$recommender_type" \
                --location="global" \
                --format=json \
                2>&1)
            
            local exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                local active_recommendations=$(echo "$recommendations" | jq '[.[] | select(.stateInfo.state == "ACTIVE" or .stateInfo.state == null)]' 2>/dev/null || echo "$recommendations")
                
                if [[ "$active_recommendations" != "[]" && -n "$active_recommendations" && "$active_recommendations" != "null" ]]; then
                    local count=$(echo "$active_recommendations" | jq 'length' 2>/dev/null || echo "0")
                    if [[ "$count" -gt 0 ]]; then
                        log "    ✅ Found $count recommendation(s) for $recommender_type"
                        local formatted_recs=$(echo "$active_recommendations" | jq --arg ba "$account_id" --arg type "$recommender_type" '[.[] | {
                                projectId: "billing-account",
                                billingAccount: $ba,
                                location: "global",
                                recommenderType: $type,
                                name: .name,
                                description: .description,
                                primaryImpact: .primaryImpact,
                                state: (.stateInfo.state // "ACTIVE"),
                                priority: .priority,
                                content: .content
                            }]')
                        all_billing_recs=$(echo "$all_billing_recs" "$formatted_recs" | jq -s 'add')
                    else
                        log "    ℹ️  No active recommendations for $recommender_type"
                    fi
                else
                    log "    ℹ️  No recommendations found for $recommender_type"
                fi
            else
                local error_msg=$(echo "$recommendations" | grep -i "error\|denied\|permission\|not found" | head -1 || echo "Unknown error")
                log "    ⚠️  Error checking $recommender_type: $error_msg"
                log "       Full error: $(echo "$recommendations" | head -3 | tr '\n' ' ')"
            fi
        done
    done <<< "$billing_accounts"
    
    echo "$all_billing_recs"
}

# Main processing
log "Starting GCP Cost Optimization Recommendations Fetch"

# Get project list - use specified projects or query all accessible projects
if [[ -z "$PROJECT_IDS" || "$PROJECT_IDS" == '""' ]]; then
    log "GCP_PROJECT_IDS not set, fetching all accessible projects..."
    PROJECT_IDS=$(gcloud projects list --format="value(projectId)" --filter="lifecycleState:ACTIVE" | tr '\n' ',' | sed 's/,$//')
    if [[ -z "$PROJECT_IDS" ]]; then
        log "⚠️  No projects found or accessible"
        log "   Set GCP_PROJECT_IDS environment variable with comma-separated project IDs"
        PROJECT_IDS=""
    else
        log "Found projects: $PROJECT_IDS"
    fi
else
    log "Using provided GCP_PROJECT_IDS: $PROJECT_IDS"
fi

# Get billing account recommendations first
billing_recs=$(get_billing_account_recommendations)
if [[ -n "$billing_recs" && "$billing_recs" != "[]" && "$billing_recs" != "null" ]]; then
    all_recommendations="$billing_recs"
    local billing_count=$(echo "$billing_recs" | jq 'length' 2>/dev/null || echo "0")
    log "Billing account recommendations collected: $billing_count"
else
    all_recommendations='[]'
fi

# Check organization-level recommenders if available
log "Checking organization-level recommendations..."
org_list_output=$(gcloud organizations list --format="value(name)" 2>&1)
org_list_exit=$?

if [[ $org_list_exit -ne 0 ]]; then
    log "  ⚠️  Cannot list organizations"
    log "     Error: $(echo "$org_list_output" | head -2 | tr '\n' ' ')"
    log "     This may be due to:"
    log "     - Insufficient permissions (need 'resourcemanager.organizations.get' permission)"
    log "     - Organization Admin role not granted to service account"
    log "     - No organization configured for this account"
fi

org_id=$(echo "$org_list_output" | grep -v "ERROR\|WARNING" | head -1)
if [[ -n "$org_id" ]]; then
    org_id_short=$(echo "$org_id" | sed 's|.*/||')
    log "  Found organization: $org_id_short"
    log "  ℹ️  Note: CUD recommendations are typically available at project level, not organization level"
    log "      They will be checked for each project below"
else
    log "  ℹ️  No organization found or insufficient permissions"
    log "     Attempting to find organization from projects..."
    
    # Try to get organization from the first accessible project
    if [[ -n "$PROJECT_IDS" ]]; then
        first_project=$(echo "$PROJECT_IDS" | cut -d',' -f1)
        project_details=$(gcloud projects describe "$first_project" --format=json 2>/dev/null)
        org_from_project=$(echo "$project_details" | jq -r '.parent.id // empty' 2>/dev/null)
        parent_type=$(echo "$project_details" | jq -r '.parent.type // empty' 2>/dev/null)
        
        if [[ -n "$org_from_project" && "$parent_type" == "organization" ]]; then
            log "     Found organization from project: $org_from_project"
            log "     NOTE: To query organization-level CUD recommendations, grant the service account:"
            log "           - 'Organization Viewer' role (roles/resourcemanager.organizationViewer)"
            log "           - 'Recommender Viewer' role (roles/recommender.viewer) at organization level"
        fi
    fi
fi

# Process each project
if [[ -n "$PROJECT_IDS" && "$PROJECT_IDS" != '""' ]]; then
    log "Processing projects for recommendations..."
    IFS=',' read -ra PROJ_ARRAY <<< "$PROJECT_IDS"
    log "Projects to check: ${#PROJ_ARRAY[@]}"
    
    if [[ ${#PROJ_ARRAY[@]} -eq 0 ]]; then
        log "⚠️  No projects to process (PROJECT_IDS is empty or invalid)"
    fi
else
    log "⚠️  Skipping project-level recommendations (no projects specified)"
    PROJ_ARRAY=()
fi

for proj_id in "${PROJ_ARRAY[@]}"; do
    proj_id=$(echo "$proj_id" | xargs)  # trim whitespace
    [[ -z "$proj_id" ]] && continue
    
    log "Processing project: $proj_id"
    
    # Check if recommender API is enabled
    if ! gcloud services list --project="$proj_id" --enabled --filter="name:recommender.googleapis.com" --format="value(name)" 2>/dev/null | grep -q "recommender.googleapis.com"; then
        log "⚠️  Recommender API not enabled for project: $proj_id"
        log "   Enable it with: gcloud services enable recommender.googleapis.com --project=$proj_id"
        continue
    fi
    
    # List available recommenders for debugging (only if verbose or no recommendations found)
    available_recommenders=$(list_available_recommenders "$proj_id")
    if [[ -n "$available_recommenders" ]]; then
        recommender_count=$(echo "$available_recommenders" | wc -l)
        log "  Available recommenders: $recommender_count types"
        # Log first few for debugging
        echo "$available_recommenders" | head -5 | while read -r rec; do
            [[ -n "$rec" ]] && log "    - $rec"
        done
    else
        log "  ⚠️  Could not list available recommenders (may need additional permissions)"
    fi
    
    # Get recommendations for each cost-related type
    log "  Checking ${#RECOMMENDATION_TYPES[@]} cost-related recommender types..."
    for recommender_type in "${RECOMMENDATION_TYPES[@]}"; do
        recs=$(get_recommendations_for_project "$proj_id" "$recommender_type")
        if [[ -n "$recs" && "$recs" != "[]" && "$recs" != "null" ]]; then
            # Count recommendations before merging
            rec_count=$(echo "$recs" | jq 'length' 2>/dev/null | head -1 || echo "0")
            if [[ "$rec_count" -gt 0 ]]; then
                log "    💰 Found $rec_count cost recommendation(s) for $recommender_type"
            fi
            # Add to all recommendations - safely merge arrays
            all_recommendations=$(jq -s '.[0] + .[1]' <(echo "$all_recommendations") <(echo "$recs"))
        fi
    done
    log "  Finished checking project: $proj_id"
done

# Count total recommendations
total_recommendations=$(echo "$all_recommendations" | jq 'length' 2>/dev/null || echo "0")
log "Total recommendations found: $total_recommendations"

# Show breakdown by source
if [[ "$total_recommendations" -gt 0 ]]; then
    log "Recommendation breakdown:"
    echo "$all_recommendations" | jq -r 'group_by(.projectId) | .[] | "  - " + .[0].projectId + ": " + (length | tostring)' 2>/dev/null || true
fi

# Generate report
cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP COST OPTIMIZATION RECOMMENDATIONS                      ║
║          From GCP Recommender API                                   ║
╚══════════════════════════════════════════════════════════════════════╝

📊 SUMMARY
$(printf '═%.0s' {1..72})

   📋 Total Recommendations: $total_recommendations
   🔐 Projects Analyzed: ${#PROJ_ARRAY[@]}

$(printf '═%.0s' {1..72})

EOF

# Separate cost and non-cost recommendations
if [[ "$total_recommendations" -gt 0 && "$all_recommendations" != "[]" ]]; then
    # Filter for cost-related recommendations
    cost_recs=$(echo "$all_recommendations" | jq '[.[] | select(
        .primaryImpact.category == "COST" or 
        .primaryImpact.costProjection != null or
        (.recommenderType | contains("commitment")) or
        (.recommenderType | contains("Idle")) or
        (.recommenderType | contains("MachineType"))
    )]')
    
    cost_count=$(echo "$cost_recs" | jq 'length')
    
    if [[ "$cost_count" -gt 0 ]]; then
        echo "" >> "$REPORT_FILE"
        echo "💰 COST OPTIMIZATION RECOMMENDATIONS ($cost_count)" >> "$REPORT_FILE"
        echo "$(printf '═%.0s' {1..72})" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        
        echo "$cost_recs" | jq -r '
            group_by(.recommenderType) |
            .[] |
            "📌 " + .[0].recommenderType + " (" + (length | tostring) + " recommendations)\n" +
            (.[] | 
                "   Project: " + .projectId + "\n" +
                "   Location: " + .location + "\n" +
                "   Priority: " + (.priority // "Unknown") + "\n" +
                "   Description: " + (.description // "N/A") + "\n" +
                (if .primaryImpact.costProjection then
                    "   💵 Estimated Monthly Savings: $" + 
                    ((.primaryImpact.costProjection.cost.units // 0) | tostring) + 
                    (if (.primaryImpact.costProjection.cost.nanos // 0) > 0 then
                        "." + (((.primaryImpact.costProjection.cost.nanos // 0) / 10000000) | tostring | .[0:2])
                    else "" end)
                else "   💵 Estimated Savings: See details in GCP Console" end) + "\n" +
                "   ────────────────────────────────────────────────────────────\n"
            )
        ' >> "$REPORT_FILE"
    else
        echo "" >> "$REPORT_FILE"
        echo "✅ No cost optimization recommendations found." >> "$REPORT_FILE"
        echo "   Your resources appear to be cost-optimized." >> "$REPORT_FILE"
    fi
    
    # Report non-cost recommendations separately (security, performance, etc.)
    other_recs=$(echo "$all_recommendations" | jq '[.[] | select(
        (.primaryImpact.category != "COST" and .primaryImpact.costProjection == null) and
        (.recommenderType | contains("commitment") | not) and
        (.recommenderType | contains("Idle") | not) and
        (.recommenderType | contains("MachineType") | not)
    )]')
    
    other_count=$(echo "$other_recs" | jq 'length')
    
    if [[ "$other_count" -gt 0 ]]; then
        echo "" >> "$REPORT_FILE"
        echo "ℹ️  OTHER RECOMMENDATIONS (Security, Performance) - $other_count" >> "$REPORT_FILE"
        echo "$(printf '─%.0s' {1..72})" >> "$REPORT_FILE"
        echo "(These are not cost-related. Review in GCP Console if needed.)" >> "$REPORT_FILE"
    fi
    
    # Generate issues JSON - ONLY for COST-related recommendations
    log "Generating issues JSON from $total_recommendations recommendations..."
    log "Filtering for COST impact recommendations only..."
    
    # Filter recommendations to only those with COST category or cost savings
    cost_recommendations=$(echo "$all_recommendations" | jq '[.[] | select(
        .primaryImpact.category == "COST" or 
        .primaryImpact.costProjection != null or
        (.recommenderType | contains("commitment")) or
        (.recommenderType | contains("Idle")) or
        (.recommenderType | contains("MachineType"))
    )]')
    
    cost_rec_count=$(echo "$cost_recommendations" | jq 'length')
    log "Found $cost_rec_count cost-related recommendations (filtered from $total_recommendations total)"
    
    if [[ "$cost_rec_count" -gt 0 ]]; then
        # Separate CUD recommendations from other cost recommendations
        cud_recommendations=$(echo "$cost_recommendations" | jq '[.[] | select(.recommenderType | contains("commitment") or contains("Commitment"))]')
        other_cost_recommendations=$(echo "$cost_recommendations" | jq '[.[] | select(.recommenderType | contains("commitment") or contains("Commitment") | not)]')
        
        cud_count=$(echo "$cud_recommendations" | jq 'length')
        other_cost_count=$(echo "$other_cost_recommendations" | jq 'length')
        
        log "Found $cud_count CUD recommendations and $other_cost_count other cost recommendations"
        
        issues="[]"
        
        # Create a single consolidated issue for all CUD recommendations
        if [[ "$cud_count" -gt 0 ]]; then
            log "Creating consolidated CUD issue from $cud_count recommendations..."
            
            # Calculate total savings and group by project
            cud_summary=$(echo "$cud_recommendations" | jq -r '
                group_by(.projectId) | 
                map({
                    project: .[0].projectId,
                    count: length,
                    total_savings: (map(select(.primaryImpact.costProjection != null) | .primaryImpact.costProjection.cost.units // 0) | add // 0),
                    regions: (map(.location) | unique | join(", "))
                }) | 
                {
                    total_count: (map(.count) | add),
                    total_savings: (map(.total_savings) | add),
                    projects: map("  • " + .project + ": " + (.count | tostring) + " recommendation(s) in " + .regions + " (Est. $" + (.total_savings | tostring) + "/mo)")
                }
            ')
            
            total_cud_count=$(echo "$cud_summary" | jq -r '.total_count')
            total_cud_savings=$(echo "$cud_summary" | jq -r '.total_savings')
            project_breakdown=$(echo "$cud_summary" | jq -r '.projects | join("\n")')
            
            # Create the consolidated CUD issue
            cud_issue=$(jq -n \
                --arg title "Committed Use Discounts (CUDs) Available - $total_cud_count Opportunities" \
                --arg savings "$total_cud_savings" \
                --arg breakdown "$project_breakdown" \
                --argjson details "$(echo "$cud_recommendations" | jq '[.[] | {projectId, location, recommenderType, priority, description, name}]')" \
                '{
                    title: $title,
                    severity: 4,
                    details: {
                        summary: "GCP recommends purchasing Committed Use Discounts (CUDs) across multiple projects and regions.",
                        totalRecommendations: ($details | length),
                        estimatedMonthlySavings: ("$" + $savings),
                        projectBreakdown: $breakdown,
                        recommendations: $details
                    },
                    next_steps: "Review CUD recommendations in GCP Console:\n1. Navigate to Billing > Commitments\n2. Review recommendations for each project/region\n3. Purchase appropriate 1-year or 3-year commitments\n4. CUDs provide up to 57% discount for consistent workloads"
                }'
            )
            
            issues=$(echo "$issues" | jq --argjson cud "$cud_issue" '. + [$cud]')
            log "✅ Created 1 consolidated CUD issue covering $cud_count recommendations"
        fi
        
        # Create individual issues for other cost recommendations (idle resources, machine types, etc.)
        if [[ "$other_cost_count" -gt 0 ]]; then
            log "Creating $other_cost_count individual issues for non-CUD cost recommendations..."
            other_issues=$(echo "$other_cost_recommendations" | jq '[.[] | {
                title: ((.description // .recommenderType) + 
                    (if .primaryImpact.costProjection then 
                        " (Est. savings: $" + ((.primaryImpact.costProjection.cost.units // 0) | tostring) + ")"
                    else "" end)),
                severity: (if .priority == "P1" or .priority == "P2" then 2
                          elif .priority == "P3" then 3
                          else 4 end),
                details: {
                    projectId: .projectId,
                    location: .location,
                    recommenderType: .recommenderType,
                    priority: (.priority // "Unknown"),
                    primaryImpact: .primaryImpact,
                    content: .content,
                    estimatedMonthlySavings: (if .primaryImpact.costProjection then 
                        "$" + ((.primaryImpact.costProjection.cost.units // 0) | tostring)
                    else "N/A" end)
                },
                next_steps: ("Review recommendation in GCP Console: " + (.name // "N/A"))
            }]')
            
            issues=$(echo "$issues" | jq --argjson other "$other_issues" '. + $other')
            log "✅ Created $other_cost_count individual issues for other cost optimizations"
        fi
        
        echo "$issues" > "$ISSUES_FILE"
    else
        echo '[]' > "$ISSUES_FILE"
    fi
    
    if [[ $? -ne 0 ]]; then
        log "⚠️  Error generating issues JSON"
    else
        log "✅ Generated $(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo "0") issues"
    fi
else
    echo "✅ No active cost optimization recommendations found." >> "$REPORT_FILE"
    echo "   All resources appear to be optimized, or recommendations need time to generate." >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

💡 NOTE: Recommendations are generated by GCP based on your usage patterns.
   Review each recommendation in the GCP Console for detailed implementation steps.

EOF

log "Report saved to: $REPORT_FILE"
log "Issues JSON saved to: $ISSUES_FILE"

# Output issues JSON file path for debugging
if [[ -f "$ISSUES_FILE" ]]; then
    issues_count=$(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    log "Issues file contains $issues_count issue(s)"
else
    log "⚠️  Warning: Issues file not found at $ISSUES_FILE"
fi

log "✅ Recommendations fetch complete!"

