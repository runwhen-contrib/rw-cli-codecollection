#!/usr/bin/env bash
set -euo pipefail
set -x

# Consolidate artifact spend findings into actionable optimization recommendations.

source "$(dirname "$0")/artifact-billing-common.sh"

REPORT_FILE="${REPORT_FILE:-artifact_recommendations_report.txt}"
ISSUES_FILE="${ISSUES_FILE:-artifact_recommendations_issues.json}"

init_issues_file "$ISSUES_FILE"

if ! ensure_billing_context; then
    cp "$ISSUES_FILE" artifact_recommendations_output.json
    cat "$ISSUES_FILE"
    exit 0
fi

lookback_start=$(echo "$DATE_RANGES" | jq -r '.lookback.start')
lookback_end=$(echo "$DATE_RANGES" | jq -r '.lookback.end')
rows=$(query_artifact_cost_rows "$BILLING_TABLE" "$lookback_start" "$lookback_end" "$PROJECT_FILTER")

total_cost=$(echo "$rows" | jq '[.[].total_cost | tonumber] | add // 0')
gcr_cost=$(echo "$rows" | jq '[.[] | select((.service_name // "") | test("Container Registry"; "i") or (.sku_description // "") | test("Container Registry"; "i")) | .total_cost | tonumber] | add // 0')
scan_cost=$(echo "$rows" | jq '[.[] | select((.sku_description // "") | test("scan"; "i")) | .total_cost | tonumber] | add // 0')
storage_cost=$(echo "$rows" | jq '[.[] | select((.sku_description // "") | test("storage|stored"; "i")) | .total_cost | tonumber] | add // 0')

top_projects=$(echo "$rows" | jq '
  group_by(.project_id) |
  map({projectId: .[0].project_id, cost: (map(.total_cost | tonumber) | add // 0)}) |
  sort_by(-.cost) | .[:5]
')

recommendations=()

if (( $(echo "$gcr_cost > 0" | bc -l) )); then
    gcr_share=$(echo "scale=1; 100 * $gcr_cost / ($total_cost + 0.0001)" | bc -l)
    recommendations+=("Migrate legacy Container Registry (gcr.io) workloads to Artifact Registry; legacy GCR represents ~${gcr_share}% of artifact spend.")
    issue=$(jq -n \
        --arg title "Retire Legacy Container Registry to Reduce Artifact Spend" \
        --argjson severity 3 \
        --arg gcr_cost "$gcr_cost" \
        --arg share "$gcr_share" \
        '{
          title: $title,
          severity: $severity,
          expected: "Production workloads should use Artifact Registry instead of legacy GCR",
          actual: ("Legacy GCR accounts for $" + $gcr_cost + " (" + $share + "% of artifact spend)"),
          details: "Legacy GCR SKUs remain in billing export and often indicate unmigrated or stale images.",
          next_steps: "Migrate images to Artifact Registry, update CI/CD references, then delete unused gcr.io repositories."
        }')
    append_issue "$ISSUES_FILE" "$issue"
fi

if (( $(echo "$storage_cost > 0" | bc -l) )) && (( $(echo "$storage_cost / ($total_cost + 0.0001) > 0.6" | bc -l) )); then
    recommendations+=("Enable Artifact Registry cleanup policies to prune untagged or aged images; storage dominates artifact spend.")
    issue=$(jq -n \
        --arg title "Enable Artifact Registry Cleanup Policies" \
        --argjson severity 3 \
        --arg storage_cost "$storage_cost" \
        '{
          title: $title,
          severity: $severity,
          expected: "Artifact storage spend should be controlled with lifecycle cleanup policies",
          actual: ("Storage SKUs account for $" + $storage_cost + " of artifact spend"),
          details: "High storage share typically indicates stale tags and missing cleanup policies.",
          next_steps: "Configure cleanup policies per repository. Use gcp-artifact-registry-governance to find repositories without policies."
        }')
    append_issue "$ISSUES_FILE" "$issue"
fi

if (( $(echo "$scan_cost > 0" | bc -l) )) && (( $(echo "$scan_cost / ($total_cost + 0.0001) > 0.15" | bc -l) )); then
    recommendations+=("Right-size vulnerability scanning scope; scanning represents a material share of artifact spend.")
    issue=$(jq -n \
        --arg title "Review Artifact Vulnerability Scanning Scope" \
        --argjson severity 4 \
        --arg scan_cost "$scan_cost" \
        '{
          title: $title,
          severity: $severity,
          expected: "Scanning spend should align with security requirements without scanning unnecessary tags",
          actual: ("Scanning SKUs cost $" + $scan_cost + " in the lookback window"),
          details: "Excessive scanning charges may indicate scanning all tags including ephemeral CI builds.",
          next_steps: "Limit scanning to production tags or enable scanning only on push to protected repositories."
        }')
    append_issue "$ISSUES_FILE" "$issue"
fi

if [[ "$(echo "$top_projects" | jq 'length')" -gt 0 ]]; then
    high_cost_projects=$(echo "$top_projects" | jq -r '.[] | select(.cost > 0) | .projectId' | paste -sd, -)
    if [[ -n "$high_cost_projects" ]]; then
        recommendations+=("Follow up on high-spend projects (${high_cost_projects}) with gcp-artifact-registry-governance inventory tasks.")
        issue=$(jq -n \
            --arg title "Cross-Reference High Artifact Spend Projects with Governance Bundle" \
            --argjson severity 4 \
            --arg projects "$high_cost_projects" \
            '{
              title: $title,
              severity: $severity,
              expected: "High artifact spend projects should be reviewed for stale artifacts and missing cleanup policies",
              actual: ("Top artifact spend projects: " + $projects),
              details: "BigQuery billing export does not expose repository names; correlate project-level spend with governance inventory.",
              next_steps: "Run gcp-artifact-registry-governance against the listed projects to identify stale images and policy gaps."
            }')
        append_issue "$ISSUES_FILE" "$issue"
    fi
fi

recommendations+=("Reduce duplicate tags by enforcing immutable tags in CI/CD and pruning redundant build artifacts.")

{
    echo "Artifact Registry Spend Optimization Summary"
    echo "============================================"
    echo "Total artifact spend (${lookback_start} to ${lookback_end}): \$$(printf "%.2f" "$total_cost")"
    echo "  Storage: \$$(printf "%.2f" "$storage_cost")"
    echo "  Legacy GCR: \$$(printf "%.2f" "$gcr_cost")"
    echo "  Scanning: \$$(printf "%.2f" "$scan_cost")"
    echo ""
    echo "Recommendations:"
    idx=1
    for rec in "${recommendations[@]}"; do
        echo "  ${idx}. ${rec}"
        idx=$((idx + 1))
    done
} | tee "$REPORT_FILE"

cp "$ISSUES_FILE" artifact_recommendations_output.json
echo "Optimization summary completed."
