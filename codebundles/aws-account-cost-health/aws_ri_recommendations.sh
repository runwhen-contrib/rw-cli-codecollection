#!/bin/bash

# AWS Reserved Instance & Savings Plans Recommendations
# Queries AWS Cost Explorer for RI and Savings Plans purchase recommendations
# and calculates potential savings.

source "$(dirname "$0")/auth.sh"
auth

ISSUES_FILE="aws_ri_issues.json"
REPORT_FILE="aws_ri_report.txt"

# Minimum monthly savings threshold to raise an issue (default: $100/month)
MIN_SAVINGS_THRESHOLD="${MIN_SAVINGS_THRESHOLD:-100}"

echo '[]' > "$ISSUES_FILE"
> "$REPORT_FILE"

# Cost Explorer is a global service; always use us-east-1 regardless of AWS_REGION
CE_REGION="us-east-1"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "unknown")
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
ACCOUNT_DISPLAY="${ACCOUNT_ALIAS:-$ACCOUNT_ID}"

log "Starting RI & Savings Plans recommendation analysis for account $ACCOUNT_DISPLAY"

total_monthly_savings=0
total_annual_savings=0
recommendation_count=0

# ============================================================
# 1. EC2 Reserved Instance Recommendations
# ============================================================
log "Querying EC2 Reserved Instance recommendations..."

for term in ONE_YEAR THREE_YEARS; do
    ec2_ri=$(aws ce get-reservation-purchase-recommendation \
        --region "$CE_REGION" \
        --service "Amazon Elastic Compute Cloud - Compute" \
        --term-in-years "$term" \
        --payment-option NO_UPFRONT \
        --lookback-period-in-days SIXTY_DAYS \
        --output json 2>/dev/null)

    if [[ $? -eq 0 && -n "$ec2_ri" ]]; then
        recs=$(echo "$ec2_ri" | jq -r '.Recommendations // []')
        rec_count=$(echo "$recs" | jq '[.[].RecommendationDetails // [] | length] | add // 0')

        if [[ "$rec_count" -gt 0 ]]; then
            log "  Found $rec_count EC2 RI recommendation(s) for $term"
            echo "$recs" | jq -r --arg term "$term" '
                .[].RecommendationDetails[]? |
                "EC2 Reserved Instance (" + $term + "):" +
                "\n  Instance Type: " + (.InstanceDetails.EC2InstanceDetails.InstanceType // "N/A") +
                "\n  Region: " + (.InstanceDetails.EC2InstanceDetails.Region // "N/A") +
                "\n  Platform: " + (.InstanceDetails.EC2InstanceDetails.Platform // "N/A") +
                "\n  Recommended Instances: " + (.RecommendedNumberOfInstancesToPurchase // "N/A") +
                "\n  Est. Monthly Savings: $" + (.EstimatedMonthlySavingsAmount // "0") +
                "\n  Upfront Cost: $" + (.UpfrontCost // "0") +
                "\n"
            ' >> "$REPORT_FILE"

            savings=$(echo "$recs" | jq '[.[].RecommendationDetails[]?.EstimatedMonthlySavingsAmount | tonumber] | add // 0')
            monthly_add=$(echo "$savings" | bc -l 2>/dev/null || echo "0")
            total_monthly_savings=$(echo "$total_monthly_savings + $monthly_add" | bc -l 2>/dev/null || echo "$total_monthly_savings")
            recommendation_count=$((recommendation_count + rec_count))
        fi
    fi
done

# ============================================================
# 2. RDS Reserved Instance Recommendations
# ============================================================
log "Querying RDS Reserved Instance recommendations..."

for term in ONE_YEAR THREE_YEARS; do
    rds_ri=$(aws ce get-reservation-purchase-recommendation \
        --region "$CE_REGION" \
        --service "Amazon Relational Database Service" \
        --term-in-years "$term" \
        --payment-option NO_UPFRONT \
        --lookback-period-in-days SIXTY_DAYS \
        --output json 2>/dev/null)

    if [[ $? -eq 0 && -n "$rds_ri" ]]; then
        recs=$(echo "$rds_ri" | jq -r '.Recommendations // []')
        rec_count=$(echo "$recs" | jq '[.[].RecommendationDetails // [] | length] | add // 0')

        if [[ "$rec_count" -gt 0 ]]; then
            log "  Found $rec_count RDS RI recommendation(s) for $term"
            echo "$recs" | jq -r --arg term "$term" '
                .[].RecommendationDetails[]? |
                "RDS Reserved Instance (" + $term + "):" +
                "\n  Instance Type: " + (.InstanceDetails.RDSInstanceDetails.InstanceType // "N/A") +
                "\n  Region: " + (.InstanceDetails.RDSInstanceDetails.Region // "N/A") +
                "\n  Database Engine: " + (.InstanceDetails.RDSInstanceDetails.DatabaseEngine // "N/A") +
                "\n  Recommended Instances: " + (.RecommendedNumberOfInstancesToPurchase // "N/A") +
                "\n  Est. Monthly Savings: $" + (.EstimatedMonthlySavingsAmount // "0") +
                "\n"
            ' >> "$REPORT_FILE"

            savings=$(echo "$recs" | jq '[.[].RecommendationDetails[]?.EstimatedMonthlySavingsAmount | tonumber] | add // 0')
            monthly_add=$(echo "$savings" | bc -l 2>/dev/null || echo "0")
            total_monthly_savings=$(echo "$total_monthly_savings + $monthly_add" | bc -l 2>/dev/null || echo "$total_monthly_savings")
            recommendation_count=$((recommendation_count + rec_count))
        fi
    fi
done

# ============================================================
# 3. ElastiCache Reserved Node Recommendations
# ============================================================
log "Querying ElastiCache Reserved Node recommendations..."

for term in ONE_YEAR THREE_YEARS; do
    ec_ri=$(aws ce get-reservation-purchase-recommendation \
        --region "$CE_REGION" \
        --service "Amazon ElastiCache" \
        --term-in-years "$term" \
        --payment-option NO_UPFRONT \
        --lookback-period-in-days SIXTY_DAYS \
        --output json 2>/dev/null)

    if [[ $? -eq 0 && -n "$ec_ri" ]]; then
        recs=$(echo "$ec_ri" | jq -r '.Recommendations // []')
        rec_count=$(echo "$recs" | jq '[.[].RecommendationDetails // [] | length] | add // 0')

        if [[ "$rec_count" -gt 0 ]]; then
            log "  Found $rec_count ElastiCache RI recommendation(s) for $term"
            echo "$recs" | jq -r --arg term "$term" '
                .[].RecommendationDetails[]? |
                "ElastiCache Reserved Node (" + $term + "):" +
                "\n  Node Type: " + (.InstanceDetails.ElastiCacheInstanceDetails.NodeType // "N/A") +
                "\n  Region: " + (.InstanceDetails.ElastiCacheInstanceDetails.Region // "N/A") +
                "\n  Recommended Nodes: " + (.RecommendedNumberOfInstancesToPurchase // "N/A") +
                "\n  Est. Monthly Savings: $" + (.EstimatedMonthlySavingsAmount // "0") +
                "\n"
            ' >> "$REPORT_FILE"

            savings=$(echo "$recs" | jq '[.[].RecommendationDetails[]?.EstimatedMonthlySavingsAmount | tonumber] | add // 0')
            monthly_add=$(echo "$savings" | bc -l 2>/dev/null || echo "0")
            total_monthly_savings=$(echo "$total_monthly_savings + $monthly_add" | bc -l 2>/dev/null || echo "$total_monthly_savings")
            recommendation_count=$((recommendation_count + rec_count))
        fi
    fi
done

# ============================================================
# 4. Savings Plans Recommendations (Compute & EC2)
# ============================================================
log "Querying Savings Plans recommendations..."

for sp_type in COMPUTE_SP EC2_INSTANCE_SP; do
    for term in ONE_YEAR THREE_YEARS; do
        sp_recs=$(aws ce get-savings-plans-purchase-recommendation \
            --region "$CE_REGION" \
            --savings-plans-type "$sp_type" \
            --term-in-years "$term" \
            --payment-option NO_UPFRONT \
            --lookback-period-in-days SIXTY_DAYS \
            --output json 2>/dev/null)

        if [[ $? -eq 0 && -n "$sp_recs" ]]; then
            rec_details=$(echo "$sp_recs" | jq -r '.SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationDetails // []')
            rec_count=$(echo "$rec_details" | jq 'length')

            if [[ "$rec_count" -gt 0 ]]; then
                sp_label="${sp_type//_/ }"
                log "  Found $rec_count $sp_label recommendation(s) for $term"
                echo "$rec_details" | jq -r --arg term "$term" --arg sp_type "$sp_type" '
                    .[] |
                    "Savings Plan (" + $sp_type + ", " + $term + "):" +
                    "\n  Hourly Commitment: $" + (.HourlyCommitmentToPurchase // "0") +
                    "\n  Est. Monthly Savings: $" + (.EstimatedMonthlySavingsAmount // "0") +
                    "\n  Est. On-Demand Cost: $" + (.CurrentAverageHourlyOnDemandSpend // "0") + "/hr" +
                    "\n"
                ' >> "$REPORT_FILE"

                savings=$(echo "$rec_details" | jq '[.[].EstimatedMonthlySavingsAmount | tonumber] | add // 0')
                monthly_add=$(echo "$savings" | bc -l 2>/dev/null || echo "0")
                total_monthly_savings=$(echo "$total_monthly_savings + $monthly_add" | bc -l 2>/dev/null || echo "$total_monthly_savings")
                recommendation_count=$((recommendation_count + rec_count))
            fi
        fi
    done
done

total_annual_savings=$(echo "scale=2; $total_monthly_savings * 12" | bc -l 2>/dev/null || echo "0")

# Summary
cat >> "$REPORT_FILE" << EOF

======================================================================
  RI & SAVINGS PLANS RECOMMENDATIONS SUMMARY
======================================================================

  Account:                       $ACCOUNT_DISPLAY ($ACCOUNT_ID)
  Total Recommendations Found:   $recommendation_count
  Total Potential Monthly Savings: \$$(printf '%.2f' $total_monthly_savings)
  Total Potential Annual Savings:  \$$(printf '%.2f' $total_annual_savings)

  Savings Plans provide flexible pricing (up to 72% off On-Demand)
  in exchange for a 1-year or 3-year commitment.

  Reserved Instances provide similar discounts for specific
  instance types and regions.

======================================================================
EOF

echo ""
cat "$REPORT_FILE"

# Generate issue if savings exceed threshold
if (( $(echo "$total_monthly_savings >= $MIN_SAVINGS_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
    if (( $(echo "$total_monthly_savings >= 5000" | bc -l 2>/dev/null || echo "0") )); then
        severity=2
    elif (( $(echo "$total_monthly_savings >= 1000" | bc -l 2>/dev/null || echo "0") )); then
        severity=3
    else
        severity=4
    fi

    monthly_fmt=$(printf '%.0f' $total_monthly_savings)
    annual_fmt=$(printf '%.0f' $total_annual_savings)

    jq -n \
        --arg title "AWS Savings Opportunity: \$${monthly_fmt}/month from Reserved Instances & Savings Plans for Account ${ACCOUNT_DISPLAY}" \
        --arg details "AWS Cost Explorer has identified opportunities to reduce costs.\n\nSummary:\n  Total Recommendations: $recommendation_count\n  Potential Monthly Savings: \$${monthly_fmt}\n  Potential Annual Savings: \$${annual_fmt}\n\nReserved Instances and Savings Plans provide significant discounts (up to 72%) vs On-Demand pricing in exchange for 1-year or 3-year commitments." \
        --arg next_step "Review recommendations in the AWS Cost Explorer console under Savings Plans and Reservations.\nAnalyze resource utilization to ensure commitments match steady-state usage.\nCompare 1-Year vs 3-Year terms based on workload stability.\nConsider Compute Savings Plans for maximum flexibility across instance families.\nPurchase via AWS Console, CLI, or API." \
        --argjson severity "$severity" \
        '[{title: $title, details: $details, severity: $severity, next_step: $next_step}]' \
        > "$ISSUES_FILE"

    log "Issue generated: \$${monthly_fmt}/month potential savings identified"
else
    if [[ "$recommendation_count" -eq 0 ]]; then
        log "No RI or Savings Plans recommendations found."
    else
        log "Recommendations found but below savings threshold (\$${MIN_SAVINGS_THRESHOLD}/month)"
    fi
fi

log "Analysis complete."
