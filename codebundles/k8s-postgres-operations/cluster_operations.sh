#!/bin/bash

# Comprehensive PostgreSQL cluster operations script
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

# Function to get cluster overview
get_cluster_overview() {
    log "Getting cluster overview..."
    
    # Get cluster resource details
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        cluster_info=$(${KUBERNETES_DISTRIBUTION_BINARY} get postgresclusters.postgres-operator.crunchydata.com \
            "$OBJECT_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null || echo "{}")
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        cluster_info=$(${KUBERNETES_DISTRIBUTION_BINARY} get postgresqls.acid.zalan.do \
            "$OBJECT_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null || echo "{}")
    else
        generate_issue "Unsupported operator" "API version $OBJECT_API_VERSION is not supported" "error"
        return 1
    fi
    
    if [[ "$cluster_info" == "{}" ]]; then
        generate_issue "Cluster not found" "Could not retrieve cluster information for $OBJECT_NAME" "error"
        return 1
    fi
    
    # Extract key information
    local cluster_status=$(echo "$cluster_info" | jq -r '.status // "unknown"')
    local spec_replicas=$(echo "$cluster_info" | jq -r '.spec.instances // .spec.numberOfInstances // "unknown"')
    
    add_report "Cluster specification - Replicas: $spec_replicas"
    add_report "Cluster status available: $(echo "$cluster_status" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo 'none')"
    
    # Get pod information
    local pod_selector=""
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        pod_selector="postgres-operator.crunchydata.com/cluster=$OBJECT_NAME"
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        pod_selector="application=spilo,cluster-name=$OBJECT_NAME"
    fi
    
    local pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
        --context "$CONTEXT" -l "$pod_selector" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null || echo "")
    
    if [[ -n "$pods" ]]; then
        add_report "Pod Status:"
        while IFS=$'\t' read -r pod_name phase ready; do
            [[ -z "$pod_name" ]] && continue
            add_report "  - $pod_name: $phase (Ready: $ready)"
        done <<< "$pods"
    else
        generate_issue "No pods found" "Could not find any pods for cluster $OBJECT_NAME" "warning"
    fi
}

# Function to check replication status
check_replication_status() {
    log "Checking replication status..."
    
    # Get a running pod to execute commands
    local running_pod=""
    local container="database"
    
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        running_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/role=master" \
            --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        container="database"
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        running_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "application=spilo,cluster-name=$OBJECT_NAME,spilo-role=master" \
            --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        container="postgres"
    fi
    
    if [[ -z "$running_pod" ]]; then
        generate_issue "No master pod found" "Could not find a running master pod for cluster $OBJECT_NAME" "error"
        return 1
    fi
    
    add_report "Using master pod: $running_pod"
    
    # Check replication slots
    local replication_slots=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
        --context "$CONTEXT" -c "$container" -- \
        psql -U postgres -t -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;" 2>/dev/null || echo "")
    
    if [[ -n "$replication_slots" ]]; then
        add_report "Replication Slots:"
        while IFS='|' read -r slot_name active restart_lsn; do
            [[ -z "$slot_name" ]] && continue
            slot_name=$(echo "$slot_name" | xargs)
            active=$(echo "$active" | xargs)
            restart_lsn=$(echo "$restart_lsn" | xargs)
            add_report "  - Slot: $slot_name, Active: $active, LSN: $restart_lsn"
        done <<< "$replication_slots"
    else
        add_report "No replication slots found or query failed"
    fi
    
    # Check streaming replication status
    local replication_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
        --context "$CONTEXT" -c "$container" -- \
        psql -U postgres -t -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;" 2>/dev/null || echo "")
    
    if [[ -n "$replication_status" ]]; then
        add_report "Streaming Replication Status:"
        while IFS='|' read -r client_addr state sent_lsn write_lsn flush_lsn replay_lsn; do
            [[ -z "$client_addr" ]] && continue
            client_addr=$(echo "$client_addr" | xargs)
            state=$(echo "$state" | xargs)
            add_report "  - Client: $client_addr, State: $state"
        done <<< "$replication_status"
    else
        add_report "No active replication connections found"
    fi
}

# Function to perform failover operations
perform_failover() {
    local target_member="${1:-}"
    
    log "Performing failover operation..."
    
    if [[ -z "$target_member" ]]; then
        log "No specific target member specified, will perform automatic failover"
    else
        log "Target member for failover: $target_member"
    fi
    
    # Get current master
    local current_master=""
    local container="database"
    
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        current_master=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/role=master" \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        container="database"
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        current_master=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "application=spilo,cluster-name=$OBJECT_NAME,spilo-role=master" \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        container="postgres"
    fi
    
    if [[ -z "$current_master" ]]; then
        generate_issue "No current master found" "Could not identify current master for failover" "error"
        return 1
    fi
    
    add_report "Current master: $current_master"
    
    # Perform failover using patronictl
    if [[ -n "$target_member" ]]; then
        # Switchover to specific member
        if ${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$current_master" \
            --context "$CONTEXT" -c "$container" -- \
            patronictl switchover "$OBJECT_NAME" --master "$current_master" --candidate "$target_member" --force; then
            add_report "Switchover initiated to member: $target_member"
        else
            generate_issue "Switchover failed" "Could not perform switchover to $target_member" "error"
            return 1
        fi
    else
        # Automatic failover
        if ${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$current_master" \
            --context "$CONTEXT" -c "$container" -- \
            patronictl failover "$OBJECT_NAME" --force; then
            add_report "Automatic failover initiated"
        else
            generate_issue "Failover failed" "Could not perform automatic failover" "error"
            return 1
        fi
    fi
    
    # Wait and verify new master
    log "Waiting for failover to complete..."
    sleep 30
    
    local new_master=""
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        new_master=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/role=master" \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        new_master=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
            -l "application=spilo,cluster-name=$OBJECT_NAME,spilo-role=master" \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    fi
    
    if [[ -n "$new_master" && "$new_master" != "$current_master" ]]; then
        add_report "Failover completed successfully. New master: $new_master"
    elif [[ -n "$target_member" && "$new_master" == "$target_member" ]]; then
        add_report "Switchover completed successfully. New master: $new_master"
    else
        generate_issue "Failover verification failed" "Could not verify successful failover completion" "warning"
    fi
}



# Function to restart cluster
restart_cluster() {
    log "Restarting PostgreSQL cluster..."
    
    # Get all pods in the cluster
    local pod_selector=""
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        pod_selector="postgres-operator.crunchydata.com/cluster=$OBJECT_NAME"
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        pod_selector="application=spilo,cluster-name=$OBJECT_NAME"
    fi
    
    local pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
        --context "$CONTEXT" -l "$pod_selector" \
        -o jsonpath='{.items[*].metadata.name}')
    
    if [[ -z "$pods" ]]; then
        generate_issue "No pods found" "Could not find any pods to restart for cluster $OBJECT_NAME" "error"
        return 1
    fi
    
    add_report "Found pods to restart: $pods"
    
    # Restart pods one by one (rolling restart)
    for pod in $pods; do
        log "Restarting pod: $pod"
        
        if ${KUBERNETES_DISTRIBUTION_BINARY} delete pod "$pod" -n "$NAMESPACE" --context "$CONTEXT"; then
            add_report "Deleted pod: $pod"
            
            # Wait for pod to be recreated and ready
            log "Waiting for pod $pod to be recreated..."
            if ${KUBERNETES_DISTRIBUTION_BINARY} wait --for=condition=Ready pod/"$pod" \
                -n "$NAMESPACE" --context "$CONTEXT" --timeout=300s 2>/dev/null; then
                add_report "Pod $pod is ready after restart"
            else
                generate_issue "Pod restart timeout" "Pod $pod did not become ready within timeout" "warning"
            fi
        else
            generate_issue "Pod deletion failed" "Could not delete pod $pod" "error"
        fi
        
        # Wait between pod restarts to ensure stability
        sleep 30
    done
    
    add_report "Cluster restart operation completed"
}

# Main execution function
main() {
    local operation="${OPERATION:-overview}"
    local target_member="${TARGET_MEMBER:-}"
    
    log "Starting PostgreSQL cluster operations"
    add_report "Target cluster: $OBJECT_NAME in namespace: $NAMESPACE"
    add_report "API Version: $OBJECT_API_VERSION"
    add_report "Operation: $operation"
    
    case "$operation" in
        "overview")
            get_cluster_overview
            check_replication_status
            ;;
        "failover")
            perform_failover "$target_member"
            ;;

        "restart")
            restart_cluster
            ;;
        "replication")
            check_replication_status
            ;;
        *)
            generate_issue "Unknown operation" "Operation '$operation' is not supported" "error"
            return 1
            ;;
    esac
}

# Execute main function
main

# Generate output report
OUTPUT_FILE="../cluster_operations_report.out"

echo "PostgreSQL Cluster Operations Report" > "$OUTPUT_FILE"
echo "====================================" >> "$OUTPUT_FILE"
echo "Cluster: $OBJECT_NAME" >> "$OUTPUT_FILE"
echo "Namespace: $NAMESPACE" >> "$OUTPUT_FILE"
echo "Operation: ${OPERATION:-overview}" >> "$OUTPUT_FILE"
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

log "Cluster operations completed. Report written to $OUTPUT_FILE"

# Exit with error code if there were critical issues
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        if echo "$issue" | grep -q '"severity": "error"'; then
            exit 1
        fi
    done
fi

exit 0

