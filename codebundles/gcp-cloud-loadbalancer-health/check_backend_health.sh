#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Load Balancer Backend Health
#
# For each backend service used by the project's load balancers, checks backend
# health status and flags unhealthy backends, draining instances, and backends
# with degraded capacity.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID    - GCP project ID hosting the load balancers
#
# OUTPUTS:
#   backend_health_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="backend_health_issues.json"
issues_json='[]'

echo "Checking backend health for project: $GCP_PROJECT_ID"

backend_services=$(gcloud compute backend-services list \
    --project="$GCP_PROJECT_ID" --format=json 2>err.log || { err_msg=$(cat err.log); rm -f err.log; echo "error:$err_msg"; })

if [[ "$backend_services" == error:* ]]; then
    err_msg=${backend_services#error:}
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot access backend services for project \`$GCP_PROJECT_ID\`" \
        --arg details "gcloud compute backend-services list failed: $err_msg" \
        --arg severity "4" \
        --arg expected "Backend services should be retrievable to assess load balancer health" \
        --arg actual "Listing backend services failed: $err_msg" \
        --arg next_steps "Verify the service account has compute.backendServices.get and compute.backendServices.getHealth permissions." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

if [ "$(echo "$backend_services" | jq 'length')" -eq 0 ]; then
    echo "No backend services found. Nothing to check."
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

report_file="backend_health_report.json"
echo "[]" > "$report_file"

echo "$backend_services" | jq -c '.[]' | while read -r bs; do
    bs_name=$(echo "$bs" | jq -r '.name')
    bs_region=$(echo "$bs" | jq -r '.region // ""')
    backends=$(echo "$bs" | jq -c '.backends // []')
    backend_count=$(echo "$backends" | jq 'length')

    if [ "$backend_count" -eq 0 ]; then
        echo "  Backend service '$bs_name' has no backends attached."
        continue
    fi

    scope_flag="--global"
    if [ -n "$bs_region" ]; then
        scope_flag="--region=$bs_region"
    fi

    health=$(gcloud compute backend-services get-health "$bs_name" \
        --project="$GCP_PROJECT_ID" $scope_flag --format=json 2>/dev/null || echo "{}")
    statuses=$(echo "$health" | jq -c '.healthStatus // []')

    if [ "$(echo "$statuses" | jq length)" -eq 0 ]; then
        echo "  Backend service '$bs_name' returned no health status."
        continue
    fi

    echo "$statuses" | jq -c '.[]' | while read -r st; do
        state=$(echo "$st" | jq -r '.healthState // "UNKNOWN"')
        ip=$(echo "$st" | jq -r '.ipAddress // "unknown"')
        instance_group=$(echo "$st" | jq -r '.instanceGroup // ""')

        rec=$(jq -n --arg bs "$bs_name" --arg ip "$ip" --arg state "$state" --arg ig "$instance_group" \
            '{backend_service:$bs, ip_address:$ip, health_state:$state, instance_group:$ig}')
        echo "$rec" | jq -c '.' >> "$report_file"

        if [ "$state" != "HEALTHY" ]; then
            severity="3"
            [ "$state" = "DRAINING" ] && severity="2"
            issue=$(jq -n \
                --arg title "Backend \`$ip\` behind service \`$bs_name\` is $state" \
                --arg details "Backend service '$bs_name' in project '$GCP_PROJECT_ID' has a backend ($ip) with health state '$state' (instance group: $instance_group). This backend is not serving traffic normally." \
                --arg severity "$severity" \
                --arg expected "All backends behind load balancer services should be healthy" \
                --arg actual "Backend '$ip' behind '$bs_name' has health state '$state'" \
                --arg next_steps "Investigate the instance(s) in the unhealthy backend group. Check the health check configuration, instance health, and security groups/firewall rules. See: gcloud compute backend-services get-health $bs_name $scope_flag --project=$GCP_PROJECT_ID" \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            echo "$issues_json" > "$ISSUES_FILE"
        fi
    done
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

# Convert the JSONL backend report into a JSON array for downstream consumption.
if [ -s "$report_file" ]; then
    jq -s '.' "$report_file" > "${report_file}.tmp" && mv "${report_file}.tmp" "$report_file"
else
    echo "[]" > "$report_file"
fi

echo "Backend health check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
