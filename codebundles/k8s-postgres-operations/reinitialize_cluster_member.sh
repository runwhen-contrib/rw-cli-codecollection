#!/bin/bash

# Script to reinitialize a failed PostgreSQL cluster member
# Supports both CrunchyDB and Zalando PostgreSQL operators

set -euo pipefail

# Arrays to collect reports and issues
OPERATION_REPORTS=()
ISSUES=()

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to generate an issue in JSON format
generate_issue() {
    local title="$1"
    local description="$2"
    local severity="${3:-warning}"
    
    issue=$(cat <<EOF
{
  "title": "$title",
  "description": "$description",
  "severity": "$severity",
  "cluster": "$OBJECT_NAME",
  "namespace": "$NAMESPACE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    ISSUES+=("$issue")
}

# Function to add operation report
add_report() {
    local message="$1"
    log "$message"
    OPERATION_REPORTS+=("$message")
}

# Function to check cluster status using patronictl
check_cluster_status() {
    local pod_name="$1"
    local container="$2"
    
    log "Checking cluster status via patronictl..."
    
    if ! cluster_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" \
        --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
        generate_issue "Failed to get cluster status" "Could not execute patronictl list command" "error"
        return 1
    fi
    
    echo "$cluster_status"
}

# Function to identify failed members
identify_failed_members() {
    local cluster_status="$1"
    
    log "Identifying failed cluster members..."
    
    # Parse JSON to find members with issues
    failed_members=$(echo "$cluster_status" | jq -r '.[] | select(.State != "running" or .Role == "Replica" and .Lag == "unknown") | .Member' 2>/dev/null || echo "")
    
    if [[ -z "$failed_members" ]]; then
        add_report "No failed members detected in the cluster"
        return 1
    fi
    
    add_report "Failed members identified: $failed_members"
    echo "$failed_members"
}

# Function to reinitialize CrunchyDB cluster member
reinitialize_crunchy_member() {
    local failed_member="$1"
    
    log "Reinitializing CrunchyDB cluster member: $failed_member"
    
    # Get the failed pod
    local failed_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
        --context "$CONTEXT" \
        -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME" \
        -o jsonpath="{.items[?(@.metadata.name=='$failed_member')].metadata.name}" 2>/dev/null || echo "")
    
    if [[ -z "$failed_pod" ]]; then
        generate_issue "Failed pod not found" "Could not locate pod for member: $failed_member" "error"
        return 1
    fi
    
    add_report "Found failed pod: $failed_pod"
    
    # Check if we can use patronictl reinit
    log "Attempting to reinitialize using patronictl..."
    
    # First, try patronictl reinit
    if ${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$failed_pod" \
        --context "$CONTEXT" -c database -- \
        patronictl reinit "$OBJECT_NAME" "$failed_member" --force 2>/dev/null; then
        
        add_report "Successfully initiated reinitialize via patronictl for member: $failed_member"
        
        # Wait and verify the reinitialize process
        log "Waiting for reinitialize to complete..."
        sleep 30
        
        # Check if the member is now healthy
        if check_member_health "$failed_member"; then
            add_report "Member $failed_member successfully reinitialized and is now healthy"
            return 0
        else
            generate_issue "Reinitialize incomplete" "Member $failed_member may still be recovering" "warning"
        fi
    else
        log "patronictl reinit failed, attempting pod restart method..."
        
        # Alternative: Delete the pod to force recreation
        if ${KUBERNETES_DISTRIBUTION_BINARY} delete pod "$failed_pod" -n "$NAMESPACE" --context "$CONTEXT"; then
            add_report "Deleted failed pod: $failed_pod for recreation"
            
            # Wait for pod to be recreated
            log "Waiting for pod recreation..."
            sleep 60
            
            # Verify new pod is running
            local new_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
                --context "$CONTEXT" \
                -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/instance=$failed_member" \
                -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
            
            if [[ -n "$new_pod" ]]; then
                add_report "New pod created: $new_pod"
                
                # Wait for pod to be ready
                if ${KUBERNETES_DISTRIBUTION_BINARY} wait --for=condition=Ready pod/"$new_pod" \
                    -n "$NAMESPACE" --context "$CONTEXT" --timeout=300s; then
                    add_report "Pod $new_pod is now ready"
                    return 0
                else
                    generate_issue "Pod not ready" "New pod $new_pod did not become ready within timeout" "error"
                    return 1
                fi
            else
                generate_issue "Pod recreation failed" "Could not find recreated pod for member: $failed_member" "error"
                return 1
            fi
        else
            generate_issue "Pod deletion failed" "Could not delete failed pod: $failed_pod" "error"
            return 1
        fi
    fi
}

# Function to reinitialize Zalando cluster member
reinitialize_zalando_member() {
    local failed_member="$1"
    
    log "Reinitializing Zalando cluster member: $failed_member"
    
    # Get the failed pod
    local failed_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
        --context "$CONTEXT" \
        -l "application=spilo,cluster-name=$OBJECT_NAME" \
        -o jsonpath="{.items[?(@.metadata.name=='$failed_member')].metadata.name}" 2>/dev/null || echo "")
    
    if [[ -z "$failed_pod" ]]; then
        generate_issue "Failed pod not found" "Could not locate pod for member: $failed_member" "error"
        return 1
    fi
    
    add_report "Found failed pod: $failed_pod"
    
    # For Zalando, try patronictl reinit first
    log "Attempting to reinitialize using patronictl..."
    
    if ${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$failed_pod" \
        --context "$CONTEXT" -c postgres -- \
        patronictl reinit "$OBJECT_NAME" "$failed_member" --force 2>/dev/null; then
        
        add_report "Successfully initiated reinitialize via patronictl for member: $failed_member"
        
        # Wait and verify
        log "Waiting for reinitialize to complete..."
        sleep 30
        
        if check_member_health "$failed_member"; then
            add_report "Member $failed_member successfully reinitialized and is now healthy"
            return 0
        else
            generate_issue "Reinitialize incomplete" "Member $failed_member may still be recovering" "warning"
        fi
    else
        log "patronictl reinit failed, attempting StatefulSet restart..."
        
        # For Zalando, we need to restart the StatefulSet pod
        if ${KUBERNETES_DISTRIBUTION_BINARY} delete pod "$failed_pod" -n "$NAMESPACE" --context "$CONTEXT"; then
            add_report "Deleted failed pod: $failed_pod for recreation"
            
            # Wait for pod to be recreated
            log "Waiting for pod recreation..."
            sleep 60
            
            # Check if new pod is running
            if ${KUBERNETES_DISTRIBUTION_BINARY} wait --for=condition=Ready pod/"$failed_pod" \
                -n "$NAMESPACE" --context "$CONTEXT" --timeout=300s 2>/dev/null; then
                add_report "Pod $failed_pod has been recreated and is ready"
                return 0
            else
                generate_issue "Pod recreation timeout" "Pod $failed_pod did not become ready within timeout" "error"
                return 1
            fi
        else
            generate_issue "Pod deletion failed" "Could not delete failed pod: $failed_pod" "error"
            return 1
        fi
    fi
}

# Function to check member health
check_member_health() {
    local member="$1"
    local max_attempts=10
    local attempt=1
    
    log "Checking health of member: $member"
    
    while [[ $attempt -le $max_attempts ]]; do
        # Get a healthy pod to check cluster status
        local healthy_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        
        if [[ -n "$healthy_pod" ]]; then
            local container="database"
            if [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
                container="postgres"
            fi
            
            if cluster_status=$(check_cluster_status "$healthy_pod" "$container"); then
                # Check if the member is now running and healthy
                local member_state=$(echo "$cluster_status" | jq -r ".[] | select(.Member==\"$member\") | .State" 2>/dev/null || echo "")
                local member_role=$(echo "$cluster_status" | jq -r ".[] | select(.Member==\"$member\") | .Role" 2>/dev/null || echo "")
                
                if [[ "$member_state" == "running" ]]; then
                    add_report "Member $member is now running with role: $member_role"
                    return 0
                fi
            fi
        fi
        
        log "Attempt $attempt/$max_attempts: Member $member not yet healthy, waiting..."
        sleep 30
        ((attempt++))
    done
    
    generate_issue "Member health check failed" "Member $member did not become healthy after $max_attempts attempts" "warning"
    return 1
}

# Main execution function
main() {
    log "Starting PostgreSQL cluster member reinitialize operation"
    add_report "Target cluster: $OBJECT_NAME in namespace: $NAMESPACE"
    add_report "API Version: $OBJECT_API_VERSION"
    
    # Determine the container name based on operator type
    local container="database"
    if [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        container="postgres"
    fi
    
    # Get a running pod to check cluster status
    local running_pod=""
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        running_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME" \
            --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        running_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "application=spilo,cluster-name=$OBJECT_NAME" \
            --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$running_pod" ]]; then
        generate_issue "No running pods found" "Could not find any running pods for cluster $OBJECT_NAME" "error"
        return 1
    fi
    
    add_report "Using pod $running_pod to check cluster status"
    
    # Get cluster status
    if ! cluster_status=$(check_cluster_status "$running_pod" "$container"); then
        return 1
    fi
    
    add_report "Cluster status retrieved successfully"
    
    # Identify failed members
    if failed_members=$(identify_failed_members "$cluster_status"); then
        # Process each failed member
        while IFS= read -r member; do
            [[ -z "$member" ]] && continue
            
            log "Processing failed member: $member"
            
            if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
                reinitialize_crunchy_member "$member"
            elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
                reinitialize_zalando_member "$member"
            else
                generate_issue "Unsupported operator" "API version $OBJECT_API_VERSION is not supported" "error"
            fi
        done <<< "$failed_members"
    else
        add_report "No failed members found - cluster appears healthy"
    fi
    
    # Final cluster status check
    log "Performing final cluster status check..."
    if final_status=$(check_cluster_status "$running_pod" "$container"); then
        add_report "Final cluster status: $(echo "$final_status" | jq -c '.')"
    fi
}

# Execute main function
main

# Generate output report
OUTPUT_FILE="../reinitialize_report.out"

echo "PostgreSQL Cluster Reinitialize Report" > "$OUTPUT_FILE"
echo "=======================================" >> "$OUTPUT_FILE"
echo "Cluster: $OBJECT_NAME" >> "$OUTPUT_FILE"
echo "Namespace: $NAMESPACE" >> "$OUTPUT_FILE"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "Operation Reports:" >> "$OUTPUT_FILE"
for report in "${OPERATION_REPORTS[@]}"; do
    echo "- $report" >> "$OUTPUT_FILE"
done

echo "" >> "$OUTPUT_FILE"
echo "Issues:" >> "$OUTPUT_FILE"
echo "[" >> "$OUTPUT_FILE"
for issue in "${ISSUES[@]}"; do
    echo "$issue," >> "$OUTPUT_FILE"
done
# Remove the last comma and close the JSON array
sed -i '$ s/,$//' "$OUTPUT_FILE"
echo "]" >> "$OUTPUT_FILE"

log "Reinitialize operation completed. Report written to $OUTPUT_FILE"

# Exit with error code if there were critical issues
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    # Check if any issues are marked as "error"
    for issue in "${ISSUES[@]}"; do
        if echo "$issue" | grep -q '"severity": "error"'; then
            exit 1
        fi
    done
fi

exit 0

