#!/usr/bin/env bash
# check_gke_version_support.sh
# Checks GKE cluster Kubernetes version support status and estimates cost impact
# of running deprecated or extended-support versions.
set -euo pipefail

for bin in gcloud jq bc; do
    command -v "$bin" &>/dev/null || { echo "Required tool $bin not found" >&2; exit 1; }
done

PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
[[ -z "$PROJECT" ]] && { echo "No GCP project set" >&2; exit 1; }

REPORT_FILE="version_support_report.txt"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/version_support_issues_$$.json"
cleanup() { rm -f "$ISSUES_TMP"; }
trap cleanup EXIT
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# GKE pricing constants (USD)
GKE_STANDARD_HOURLY="0.10"
GKE_EXTENDED_SURCHARGE_HOURLY="0.50"
GKE_EXTENDED_TOTAL_HOURLY="0.60"
HOURS_PER_MONTH=730

standard_monthly=$(echo "scale=2; $GKE_STANDARD_HOURLY * $HOURS_PER_MONTH" | bc -l)
surcharge_monthly=$(echo "scale=2; $GKE_EXTENDED_SURCHARGE_HOURLY * $HOURS_PER_MONTH" | bc -l)
extended_monthly=$(echo "scale=2; $GKE_EXTENDED_TOTAL_HOURLY * $HOURS_PER_MONTH" | bc -l)
surcharge_annual=$(echo "scale=2; $surcharge_monthly * 12" | bc -l)

log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr()  { printf -- '─%.0s' {1..80} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }

add_issue() {
    local TITLE="$1" DETAILS="$2" SEV="$3" NEXT="$4" SUMMARY="${5:-}"
    log "  Issue: $TITLE (severity=$SEV)"
    $first_issue || echo "," >> "$ISSUES_TMP"; first_issue=false
    jq -n --arg t "$TITLE" --arg d "$DETAILS" --arg n "$NEXT" \
        --argjson s "$SEV" --arg summary "$SUMMARY" \
        '{title:$t, details:$d, severity:$s, next_steps:$n, summary:$summary}' >> "$ISSUES_TMP"
}

# Extract minor version from GKE version strings like "1.28.5-gke.1234567"
minor_version() {
    echo "$1" | grep -oE '^[0-9]+\.[0-9]+' | head -1
}

minor_num() {
    echo "$1" | cut -d. -f2
}

printf "GKE Kubernetes Version Support Check — %s\nProject: %s\n" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$PROJECT" > "$REPORT_FILE"
hr

echo "============================================"
echo "GKE Kubernetes Version Support Check"
echo "Project: $PROJECT"
echo "============================================"
echo ""

# Fetch all clusters
CLUSTERS_JSON="$(gcloud container clusters list --project="$PROJECT" --format=json 2>/dev/null)"
if [[ "$CLUSTERS_JSON" == "[]" || -z "$CLUSTERS_JSON" ]]; then
    echo "No GKE clusters found in project $PROJECT"
    log "No GKE clusters found."
    echo "]" >> "$ISSUES_TMP"
    jq . "$ISSUES_TMP" > version_support_issues.json
    rm -f "$ISSUES_TMP"
    exit 0
fi

cluster_count=$(echo "$CLUSTERS_JSON" | jq 'length')
echo "Found $cluster_count cluster(s)"
echo ""

# Cache server configs per location to avoid redundant API calls
declare -A SERVER_CONFIG_CACHE

get_server_config() {
    local location="$1"
    if [[ -z "${SERVER_CONFIG_CACHE[$location]+_}" ]]; then
        SERVER_CONFIG_CACHE["$location"]=$(gcloud container get-server-config \
            --location "$location" --project "$PROJECT" --format=json 2>/dev/null || echo "{}")
    fi
    echo "${SERVER_CONFIG_CACHE[$location]}"
}

while IFS= read -r cluster_row; do
    cluster_name=$(echo "$cluster_row" | jq -r '.name')
    cluster_location=$(echo "$cluster_row" | jq -r '.location')
    master_version=$(echo "$cluster_row" | jq -r '.currentMasterVersion')
    node_version=$(echo "$cluster_row" | jq -r '.currentNodeVersion // "unknown"')
    release_channel=$(echo "$cluster_row" | jq -r '.releaseChannel.channel // "UNSPECIFIED"')
    cluster_status=$(echo "$cluster_row" | jq -r '.status')
    node_count=$(echo "$cluster_row" | jq '[.nodePools[]?.initialNodeCount // 0] | add // 0')

    master_minor=$(minor_version "$master_version")
    master_minor_num=$(minor_num "$master_minor")

    echo "--------------------------------------------"
    echo "Cluster: $cluster_name ($cluster_location)"
    echo "--------------------------------------------"
    echo "  Master Version:    $master_version (minor: $master_minor)"
    echo "  Node Version:      $node_version"
    echo "  Release Channel:   $release_channel"
    echo "  Status:            $cluster_status"
    echo ""

    log "Cluster: $cluster_name ($cluster_location)"
    log "  Master Version: $master_version"
    log "  Node Version:   $node_version"
    log "  Release Channel: $release_channel"

    # Fetch valid versions for this location
    server_config=$(get_server_config "$cluster_location")
    valid_master_versions=$(echo "$server_config" | jq -r '.validMasterVersions[]? // empty' 2>/dev/null)
    default_cluster_version=$(echo "$server_config" | jq -r '.defaultClusterVersion // empty' 2>/dev/null)

    if [[ -z "$valid_master_versions" ]]; then
        echo "  Warning: Could not fetch valid versions for location $cluster_location"
        log "  Warning: Could not fetch valid versions"
        hr
        continue
    fi

    # Build set of valid minor versions
    valid_minors=$(echo "$valid_master_versions" | while read -r v; do minor_version "$v"; done | sort -t. -k1,1n -k2,2n | uniq)
    latest_minor=$(echo "$valid_minors" | tail -1)
    latest_minor_num=$(minor_num "$latest_minor")

    echo "  Valid minor versions: $(echo $valid_minors | tr '\n' ' ')"
    echo "  Latest minor:         $latest_minor"
    echo "  Default version:      $default_cluster_version"
    echo ""

    # Check if master version is in valid versions (exact match)
    version_exact_match=false
    for v in $valid_master_versions; do
        if [[ "$v" == "$master_version" ]]; then
            version_exact_match=true
            break
        fi
    done

    # Check if minor version is in valid minors
    minor_match=false
    for v in $valid_minors; do
        if [[ "$v" == "$master_minor" ]]; then
            minor_match=true
            break
        fi
    done

    versions_behind=$((latest_minor_num - master_minor_num))

    # Check node pool versions for skew
    node_pool_details=""
    node_pool_version_issues=""
    while IFS= read -r np; do
        np_name=$(echo "$np" | jq -r '.name')
        np_version=$(echo "$np" | jq -r '.version // "unknown"')
        np_count=$(echo "$np" | jq -r '.initialNodeCount // 0')
        np_machine=$(echo "$np" | jq -r '.config.machineType // "unknown"')
        node_pool_details+="    $np_name: K8s $np_version | Nodes: $np_count | Machine: $np_machine\n"

        np_minor=$(minor_version "$np_version")
        if [[ "$np_minor" != "$master_minor" ]]; then
            node_pool_version_issues+="Node pool '$np_name' ($np_version) differs from master ($master_version). "
        fi
    done < <(echo "$cluster_row" | jq -c '.nodePools[]? // empty')

    if [[ -n "$node_pool_details" ]]; then
        echo "  Node Pools:"
        echo -e "$node_pool_details"
    fi

    if [[ "$minor_match" == "false" ]]; then
        echo "  ⚠️  CRITICAL: Minor version $master_minor is NOT in the valid versions for $cluster_location"
        echo "     This cluster is running a deprecated/end-of-life Kubernetes version."
        echo ""
        echo "  COST IMPACT:"
        echo "     Extended support surcharge: +\$$surcharge_monthly/month per cluster"
        echo "     Standard: \$$standard_monthly/month → Extended: \$$extended_monthly/month (6x)"
        echo "     Annual surcharge: \$$surcharge_annual/year per cluster"
        echo ""

        log "  STATUS: DEPRECATED / END OF LIFE"
        log "  Extended support surcharge: +\$$surcharge_monthly/month"

        add_issue \
            "GKE Cluster \`$cluster_name\` Running Deprecated Kubernetes $master_version (+\$$surcharge_monthly/mo surcharge)" \
            "Cluster: $cluster_name | Location: $cluster_location | Version: $master_version | Release Channel: $release_channel | Latest Available: $latest_minor | Versions Behind: $versions_behind\n\nVERSION STATUS: DEPRECATED / EXTENDED SUPPORT\nKubernetes $master_minor is not in the valid master versions for $cluster_location. This cluster is in or past the extended support period.\n\nCOST IMPACT:\n- GKE extended support surcharge: +\$0.50/hr per cluster = +\$$surcharge_monthly/month\n- Standard management fee: \$$standard_monthly/month\n- Extended support total: \$$extended_monthly/month (6x standard)\n- Annual surcharge: \$$surcharge_annual per cluster\n- Note: Extended support surcharge is included in GKE Enterprise edition at no additional cost\n\nGKE EXTENDED SUPPORT DETAILS:\n- Standard support: ~14 months per minor version\n- Extended support: ~10 additional months (24 months total)\n- Clusters receive security patches during extended support\n- After extended support: GKE auto-upgrades to a supported version\n$([[ -n "$node_pool_version_issues" ]] && echo "\nNODE POOL SKEW: $node_pool_version_issues")" \
            1 \
            "Immediately plan upgrade of GKE cluster \`$cluster_name\` to a supported Kubernetes version (latest: $latest_minor).\nReview GKE version support policy: https://cloud.google.com/kubernetes-engine/versioning\nEnroll the cluster in a release channel (Regular or Stable) to receive automatic upgrades.\nTest workload compatibility with the target version in a staging environment.\nUpdate node pools after master upgrade.\nConsider GKE Enterprise if extended support is regularly needed (surcharge included)." \
            "GKE cluster \`$cluster_name\` is running deprecated Kubernetes $master_version which is $versions_behind minor versions behind the latest ($latest_minor). This incurs an extended support surcharge of \$$surcharge_monthly/month per cluster on top of the standard \$$standard_monthly/month management fee. Upgrade to a supported version to eliminate the surcharge and ensure continued security patches."

    elif [[ $versions_behind -ge 3 ]]; then
        echo "  ⚠️  WARNING: Version $master_minor is $versions_behind minor versions behind latest ($latest_minor)"
        echo "     Likely in or approaching extended support with additional charges."
        echo ""
        echo "  COST IMPACT:"
        echo "     Extended support surcharge: +\$$surcharge_monthly/month per cluster"
        echo "     Standard: \$$standard_monthly/month → Extended: \$$extended_monthly/month"
        echo ""

        log "  STATUS: LIKELY IN EXTENDED SUPPORT"

        add_issue \
            "GKE Cluster \`$cluster_name\` Likely in Extended Support on Kubernetes $master_version (+\$$surcharge_monthly/mo surcharge)" \
            "Cluster: $cluster_name | Location: $cluster_location | Version: $master_version | Release Channel: $release_channel | Latest: $latest_minor | Versions Behind: $versions_behind\n\nVERSION STATUS: LIKELY IN EXTENDED SUPPORT\nKubernetes $master_minor is $versions_behind minor versions behind the latest ($latest_minor).\n\nCOST IMPACT:\n- Extended support surcharge: +\$0.50/hr per cluster = +\$$surcharge_monthly/month\n- Standard: \$$standard_monthly/month → Extended: \$$extended_monthly/month (6x)\n- Annual surcharge: \$$surcharge_annual per cluster\n- Included in GKE Enterprise at no extra cost\n$([[ -n "$node_pool_version_issues" ]] && echo "\nNODE POOL SKEW: $node_pool_version_issues")" \
            2 \
            "Plan upgrade of GKE cluster \`$cluster_name\` from $master_version to a recent version (latest: $latest_minor) to eliminate the extended support surcharge.\nReview GKE release notes for breaking changes.\nEnroll in a release channel for automatic upgrades.\nTest workload compatibility before upgrading." \
            "GKE cluster \`$cluster_name\` is running Kubernetes $master_version which is $versions_behind versions behind the latest ($latest_minor), likely incurring an extended support surcharge of \$$surcharge_monthly/month."

    elif [[ $versions_behind -ge 2 ]]; then
        echo "  ℹ️  Version $master_minor is $versions_behind minor versions behind latest ($latest_minor)"
        echo "     Approaching end of standard support — plan upgrade."
        echo ""

        log "  STATUS: NEARING END OF STANDARD SUPPORT"

        add_issue \
            "GKE Cluster \`$cluster_name\` Approaching End of Standard Support on Kubernetes $master_version" \
            "Cluster: $cluster_name | Location: $cluster_location | Version: $master_version | Latest: $latest_minor | Versions Behind: $versions_behind | Release Channel: $release_channel\n\nVERSION STATUS: NEARING END OF STANDARD SUPPORT\nKubernetes $master_minor is $versions_behind minor versions behind the latest. This version will enter extended support soon.\n\nUPCOMING COST IMPACT:\n- Extended support surcharge: +\$0.50/hr = +\$$surcharge_monthly/month per cluster\n- Annual surcharge: \$$surcharge_annual per cluster\n\nUpgrade before extended support begins to avoid the surcharge.\n$([[ -n "$node_pool_version_issues" ]] && echo "\nNODE POOL SKEW: $node_pool_version_issues")" \
            3 \
            "Schedule upgrade of GKE cluster \`$cluster_name\` to a recent Kubernetes version before extended support charges apply.\nReview the GKE version support schedule.\nEnroll in a release channel for automatic upgrades.\nTest workload compatibility in a staging environment." \
            "GKE cluster \`$cluster_name\` is running Kubernetes $master_version, $versions_behind versions behind the latest ($latest_minor), and will soon enter extended support with a \$$surcharge_monthly/month surcharge."
    else
        echo "  ✅  Version $master_minor is current ($versions_behind version(s) behind latest $latest_minor)"
        echo ""
        log "  STATUS: CURRENT"
    fi

    if [[ -n "$node_pool_version_issues" ]]; then
        echo "  ⚠️  Node pool version skew: $node_pool_version_issues"
        echo ""
    fi

    hr
done < <(echo "$CLUSTERS_JSON" | jq -c '.[]')

echo "]" >> "$ISSUES_TMP"
jq . "$ISSUES_TMP" > version_support_issues.json

issue_count=$(jq 'length' version_support_issues.json)
echo ""
echo "============================================"
echo "Version support check complete. Issues found: $issue_count"
echo "============================================"
echo ""
echo "GKE Extended Support Pricing Reference:"
echo "  Standard management fee: \$0.10/hr (\$$standard_monthly/month)"
echo "  Extended support:        \$0.60/hr (\$$extended_monthly/month) — 6x standard"
echo "  Surcharge per cluster:   \$0.50/hr (\$$surcharge_monthly/month, \$$surcharge_annual/year)"
echo "  GKE Enterprise: Extended support surcharge included"
echo "============================================"

log ""
log "GKE Extended Support Pricing Reference:"
log "  Standard: \$0.10/hr (\$$standard_monthly/month)"
log "  Extended: \$0.60/hr (\$$extended_monthly/month) — surcharge \$0.50/hr"
hr

echo "Report:  $REPORT_FILE"
echo "Issues:  version_support_issues.json"
