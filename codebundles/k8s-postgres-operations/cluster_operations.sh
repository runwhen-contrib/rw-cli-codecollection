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
    local next_steps="${4:-Review the operation logs and check cluster status manually}"
    
    issue=$(cat <<EOF
{
  "title": "$title",
  "description": "$description",
  "severity": "$severity",
  "cluster": "$OBJECT_NAME",
  "namespace": "$NAMESPACE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "next_steps": "$next_steps"
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

# Function to get the actual Patroni cluster name
get_patroni_cluster_name() {
    local running_pod="$1"
    local container="$2"
    
    local cluster_status=""
    if cluster_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
        --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
        echo "$cluster_status" | jq -r '.[0].Cluster' 2>/dev/null || echo "$OBJECT_NAME"
    else
        echo "$OBJECT_NAME"
    fi
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
        generate_issue "Unsupported operator" "API version $OBJECT_API_VERSION is not supported" "error" "Update the OBJECT_API_VERSION to use either postgres-operator.crunchydata.com or acid.zalan.do"
        return 1
    fi
    
    if [[ "$cluster_info" == "{}" ]]; then
        generate_issue "Cluster not found" "Could not retrieve cluster information for $OBJECT_NAME" "error" "Verify the cluster name and namespace are correct, check if the cluster exists: kubectl get postgresclusters -n $NAMESPACE"
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
        generate_issue "No pods found" "Could not find any pods for cluster $OBJECT_NAME" "warning" "Check if cluster pods are running: kubectl get pods -n $NAMESPACE -l postgres-operator.crunchydata.com/cluster=$OBJECT_NAME"
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
        generate_issue "No master pod found" "Could not find a running master pod for cluster $OBJECT_NAME" "error" "Check cluster status and pod health: kubectl get pods -n $NAMESPACE, then investigate why no master pod is available"
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
        generate_issue "No current master found" "Could not identify current master for failover" "error" "Check cluster status: kubectl exec <pod> -c database -- patronictl list, investigate cluster leadership issues"
        return 1
    fi
    
    add_report "Current master: $current_master"
    
    # Get the actual Patroni cluster name
    local patroni_cluster_name=$(get_patroni_cluster_name "$current_master" "$container")
    add_report "Using Patroni cluster name: $patroni_cluster_name"
    
    # Perform failover using patronictl
    add_report "Executing failover command..."
    local failover_output=""
    if [[ -n "$target_member" ]]; then
        # Switchover to specific member
        add_report "Attempting switchover to specific member: $target_member"
        if failover_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$current_master" \
            --context "$CONTEXT" -c "$container" -- \
            patronictl switchover "$patroni_cluster_name" --master "$current_master" --candidate "$target_member" --force 2>&1); then
            add_report "Switchover command completed successfully"
            add_report "Switchover output: $failover_output"
        else
            add_report "Switchover command failed with output: $failover_output"
            generate_issue "Switchover failed" "Could not perform switchover to $target_member. Output: $failover_output" "error" "Check target member health and cluster status: kubectl exec <pod> -c database -- patronictl list"
            return 1
        fi
    else
        # Automatic failover - first get available replicas
        add_report "Attempting automatic failover - first identifying suitable candidates"
        
        # Get current cluster status to find suitable replicas
        local cluster_status=""
        if cluster_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$current_master" \
            --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
            
            # Find healthy replicas (running state, low lag)
            local suitable_candidates=$(echo "$cluster_status" | jq -r '.[] | select(.Role == "Replica" and .State == "running" and ((.["Lag in MB"] // .Lag // 0) | tonumber) < 1000) | .Member' 2>/dev/null || echo "")
            
            if [[ -n "$suitable_candidates" ]]; then
                # Choose the first suitable candidate
                local chosen_candidate=$(echo "$suitable_candidates" | head -1)
                add_report "Available candidates: $suitable_candidates"
                add_report "Choosing candidate for failover: $chosen_candidate"
                
                # Perform switchover to the chosen candidate
                if failover_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$current_master" \
            --context "$CONTEXT" -c "$container" -- \
                    patronictl switchover "$patroni_cluster_name" --master "$current_master" --candidate "$chosen_candidate" --force 2>&1); then
                    add_report "Switchover to $chosen_candidate completed successfully"
                    add_report "Switchover command output: $failover_output"
                else
                    add_report "Switchover to $chosen_candidate failed with output: $failover_output"
                    generate_issue "Switchover failed" "Could not perform switchover to $chosen_candidate. Output: $failover_output" "error" "Investigate candidate replica health and try manual switchover: kubectl exec <pod> -c database -- patronictl switchover <cluster> --candidate <replica> --force"
                    return 1
                fi
            else
                add_report "No suitable candidates found for automatic failover"
                add_report "Current cluster status: $(echo "$cluster_status" | jq -c '.')"
                generate_issue "No suitable failover candidates" "Patroni requires a specific candidate but no suitable replicas found. All replicas may have high lag or be unhealthy." "error" "Check replica health and lag: kubectl exec <pod> -c database -- patronictl list, address replica issues before attempting failover"
                return 1
            fi
        else
            add_report "Could not get cluster status for candidate selection"
            # Try the original failover command anyway
            if failover_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$current_master" \
                --context "$CONTEXT" -c "$container" -- \
                patronictl failover "$patroni_cluster_name" --force 2>&1); then
                add_report "Automatic failover command completed successfully"
                add_report "Failover command output: $failover_output"
            else
                add_report "Automatic failover command failed with output: $failover_output"
                if echo "$failover_output" | grep -qi "could be performed only to a specific candidate"; then
                    generate_issue "Failover requires specific candidate" "Patroni requires specifying a candidate replica for failover, but no candidate was provided. Available replicas need to be identified first." "error" "List available replicas: kubectl exec <pod> -c database -- patronictl list, then specify a candidate for switchover"
                else
                    generate_issue "Failover failed" "Could not perform automatic failover. Output: $failover_output" "error" "Review failover output and cluster status: kubectl exec <pod> -c database -- patronictl list, address any cluster health issues"
                fi
            return 1
            fi
        fi
    fi
    
    # Wait and verify new master using patronictl
    log "Waiting for failover to complete..."
    add_report "Starting failover verification process..."
    sleep 30
    
    local failover_successful=false
    local new_master=""
    local verification_attempts=0
    
    # Try multiple times to verify failover as it may take time
    add_report "Beginning verification attempts to check if master changed..."
    for attempt in {1..6}; do
        verification_attempts=$attempt
        log "Failover verification attempt $attempt/6..."
        add_report "Verification attempt $attempt/6: Checking current master..."
        
        # Use patronictl to get the current cluster status (try current master first, then any pod)
        local verification_pod="$current_master"
        if ! new_cluster_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$verification_pod" \
            --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
            # If current master is unavailable, try to find any running pod
            local any_pod=""
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
                any_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
                    -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME" \
                    --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
                any_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
            --context "$CONTEXT" \
                    -l "application=spilo,cluster-name=$OBJECT_NAME" \
                    --field-selector=status.phase=Running \
            -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    fi
    
            if [[ -n "$any_pod" ]]; then
                verification_pod="$any_pod"
                new_cluster_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$verification_pod" \
                    --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null || echo "")
            fi
        fi
        
        if [[ -n "$new_cluster_status" ]]; then
            
            new_master=$(echo "$new_cluster_status" | jq -r '.[] | select(.Role == "Leader") | .Member' 2>/dev/null || echo "")
            
            if [[ -n "$new_master" ]]; then
                if [[ -n "$target_member" && "$new_master" == "$target_member" ]]; then
                    add_report "Switchover completed successfully. New master: $new_master (was: $current_master)"
                    failover_successful=true
                    break
                elif [[ -z "$target_member" && "$new_master" != "$current_master" ]]; then
                    add_report "Automatic failover completed successfully. New master: $new_master (was: $current_master)"
                    failover_successful=true
                    break
                elif [[ "$new_master" == "$current_master" ]]; then
                    add_report "Attempt $attempt: Master unchanged ($current_master), waiting..."
                    sleep 10
                else
                    add_report "Unexpected failover result. New master: $new_master (expected: ${target_member:-"different from $current_master"})"
                    break
                fi
            else
                add_report "Attempt $attempt: Could not determine new master, waiting..."
                sleep 10
            fi
        else
            add_report "Attempt $attempt: Could not get cluster status, waiting..."
            sleep 10
        fi
    done
    
    if [[ "$failover_successful" == "false" ]]; then
        if [[ "$new_master" == "$current_master" ]]; then
            generate_issue "Failover did not occur" "Master is still $current_master after $verification_attempts attempts. Failover may have failed or been rejected by Patroni." "error" "Investigate why failover was rejected: check replica health, lag, and Patroni configuration. Consider manual intervention."
            add_report "Analyzing why failover failed..."
            
            # Check replica status and lag
            if [[ -n "$new_cluster_status" ]]; then
                add_report "Current cluster status after failover attempt:"
                echo "$new_cluster_status" | jq -r '.[] | "  - \(.Member): \(.State) (\(.Role)) - Lag: \(.["Lag in MB"] // .Lag // .["Lag behind"] // "N/A") MB"' 2>/dev/null | while read -r line; do
                    add_report "$line"
                done
                
                # Check if any replicas are suitable for promotion
                local suitable_replicas=$(echo "$new_cluster_status" | jq -r '.[] | select(.Role == "Replica" and .State == "running" and ((.["Lag in MB"] // .Lag // 0) | tonumber) < 1000) | .Member' 2>/dev/null || echo "")
                if [[ -z "$suitable_replicas" ]]; then
                    add_report "No suitable replicas found for promotion (all replicas may have high lag or be unhealthy)"
                else
                    add_report "Suitable replicas available: $suitable_replicas"
                fi
            fi
            
            add_report "Possible reasons for failover failure:"
            add_report "  - No suitable replica available for promotion"
            add_report "  - Replica lag too high for safe failover (check lag above)"
            add_report "  - Patroni configuration preventing automatic failover"
            add_report "  - Network issues preventing leader election"
            add_report "  - Master is still healthy and Patroni rejected the failover"
            add_report "Manual investigation: kubectl exec $current_master -c $container -- patronictl list"
        else
            generate_issue "Failover verification failed" "Could not verify failover completion after $verification_attempts attempts. Current master: ${new_master:-"unknown"}" "warning" "Manually verify cluster status: kubectl exec <pod> -c database -- patronictl list, check if failover actually occurred"
        fi
    fi
}



# Function to restart cluster
restart_cluster() {
    log "Performing PostgreSQL cluster restart via Patroni..."
    
    # Get only PostgreSQL instance pods (not pgadmin, pgbouncer, repo-host, etc.)
    local pod_selector=""
    if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
        pod_selector="postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/instance"
    elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        pod_selector="application=spilo,cluster-name=$OBJECT_NAME"
    fi
    
    local pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
        --context "$CONTEXT" -l "$pod_selector" \
        -o jsonpath='{.items[*].metadata.name}')
    
    if [[ -z "$pods" ]]; then
        generate_issue "No PostgreSQL instance pods found" "Could not find any PostgreSQL instance pods for cluster $OBJECT_NAME" "error" "Check if PostgreSQL instances are running: kubectl get pods -n $NAMESPACE -l postgres-operator.crunchydata.com/instance"
        return 1
    fi
    
    add_report "Found PostgreSQL instance pods: $pods"
    
    # Verify these are actual Patroni cluster members by checking with patronictl
    local container="database"
    if [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        container="postgres"
    fi
    
    # Get actual cluster members from Patroni
    local first_pod=$(echo "$pods" | awk '{print $1}')
    local patroni_members=""
    if patroni_members=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$first_pod" \
        --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
        local actual_members=$(echo "$patroni_members" | jq -r '.[].Member' 2>/dev/null | tr '\n' ' ')
        add_report "Actual Patroni cluster members: $actual_members"
        # Use only the actual Patroni members
        pods="$actual_members"
    else
        add_report "Could not verify Patroni members, using pod selector results"
    fi
    
    # Use Patroni to perform proper rolling restart
    local container="database"
    if [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
        container="postgres"
    fi
    
    # Get the leader pod for executing patroni commands
    local leader_pod=""
    for pod in $pods; do
        local pod_role=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod" \
            --context "$CONTEXT" -c "$container" -- \
            patronictl list -f json 2>/dev/null | jq -r --arg pod "$pod" '.[] | select(.Member == $pod) | .Role' 2>/dev/null || echo "")
        if [[ "$pod_role" == "Leader" ]]; then
            leader_pod="$pod"
            break
        fi
    done
    
    if [[ -z "$leader_pod" ]]; then
        generate_issue "No leader found" "Could not identify cluster leader for restart operation" "error" "Check cluster leadership: kubectl exec <pod> -c database -- patronictl list, investigate cluster health issues"
        return 1
    fi
    
    add_report "Using leader pod $leader_pod for restart operations"
    
    # Get the actual Patroni cluster name
    local patroni_cluster_name=$(get_patroni_cluster_name "$leader_pod" "$container")
    add_report "Using Patroni cluster name: $patroni_cluster_name"
    
    # Restart each member using patronictl
    for pod in $pods; do
        if [[ "$pod" == "$leader_pod" ]]; then
            add_report "Skipping leader $pod for now - will restart last"
            continue
        fi
        
        log "Restarting replica: $pod"
        local restart_output=""
        if restart_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$leader_pod" \
            --context "$CONTEXT" -c "$container" -- \
            patronictl restart "$patroni_cluster_name" "$pod" --force 2>&1); then
            add_report "Successfully restarted replica $pod via patronictl"
            add_report "Restart output: $restart_output"
        else
            add_report "Failed to restart replica $pod via patronictl: $restart_output"
            generate_issue "Replica restart failed" "Could not restart replica $pod using patronictl: $restart_output" "warning" "Check pod health and try manual restart: kubectl exec <leader-pod> -c database -- patronictl restart <cluster> <member> --force"
        fi
        
        # Wait between restarts for stability
        sleep 30
    done
    
    # Finally restart the leader
    log "Restarting leader: $leader_pod"
    local leader_restart_output=""
    if leader_restart_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$leader_pod" \
        --context "$CONTEXT" -c "$container" -- \
        patronictl restart "$patroni_cluster_name" "$leader_pod" --force 2>&1); then
        add_report "Successfully restarted leader $leader_pod via patronictl"
        add_report "Leader restart output: $leader_restart_output"
    else
        add_report "Failed to restart leader $leader_pod via patronictl: $leader_restart_output"
        generate_issue "Leader restart failed" "Could not restart leader $leader_pod using patronictl: $leader_restart_output" "error" "Check leader pod health and try manual restart: kubectl exec <pod> -c database -- patronictl restart <cluster> <leader> --force"
    fi
    
    add_report "Cluster restart operation completed using Patroni rolling restart"
    add_report "NOTE: Patroni restart is preferred over pod deletion as it maintains cluster consistency"
}

# Function to reinitialize failed cluster members
reinitialize_failed_members() {
    log "Starting cluster member reinitialize operation..."
    
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
        generate_issue "No running pods found" "Could not find any running pods for cluster $OBJECT_NAME" "error" "Check cluster pod status: kubectl get pods -n $NAMESPACE, investigate why no pods are running"
        return 1
    fi
    
    add_report "Using pod $running_pod to check cluster status"
    
    # Get cluster status using patronictl
    log "Checking cluster status via patronictl..."
    if ! cluster_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
        --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
        generate_issue "Failed to get cluster status" "Could not execute patronictl list command" "error" "Check pod connectivity and Patroni service: kubectl exec <pod> -c database -- patronictl list"
        return 1
    fi
    
    add_report "Cluster status retrieved successfully"
    
    # Debug: Show available fields in the JSON structure
    add_report "Available fields in cluster status: $(echo "$cluster_status" | jq -r '.[0] | keys | join(", ")' 2>/dev/null || echo "unknown")"
    
    # Extract the actual Patroni cluster name from the status
    local patroni_cluster_name=$(echo "$cluster_status" | jq -r '.[0].Cluster' 2>/dev/null || echo "$OBJECT_NAME")
    if [[ "$patroni_cluster_name" != "$OBJECT_NAME" ]]; then
        add_report "Detected Patroni cluster name: $patroni_cluster_name (differs from K8s object name: $OBJECT_NAME)"
    else
        add_report "Patroni cluster name matches K8s object name: $patroni_cluster_name"
    fi
    
    # Report current cluster member status with lag information
    add_report "Current cluster member status:"
    echo "$cluster_status" | jq -r '.[] | "  - \(.Member): \(.State) (\(.Role)) - Lag: \(.["Lag in MB"] // .Lag // .["Lag behind"] // "N/A") MB"' 2>/dev/null | while read -r line; do
        add_report "$line"
    done
    
    # If lag information is not available from patronictl, try to get it directly from PostgreSQL
    local has_lag_info=$(echo "$cluster_status" | jq -r '.[0] | has("Lag in MB") or has("Lag") or has("Lag behind")' 2>/dev/null || echo "false")
    if [[ "$has_lag_info" == "false" ]]; then
        add_report "Lag information not available from patronictl, attempting to get replication lag from PostgreSQL..."
        
        # Find the leader pod
        local leader_pod=$(echo "$cluster_status" | jq -r '.[] | select(.Role == "Leader") | .Member' 2>/dev/null || echo "")
        if [[ -n "$leader_pod" ]]; then
            # Get replication lag from pg_stat_replication
            local replication_lag=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$leader_pod" \
                --context "$CONTEXT" -c "$container" -- \
                psql -U postgres -t -c "SELECT client_addr, application_name, COALESCE(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), 'N/A') as lag FROM pg_stat_replication;" 2>/dev/null || echo "")
            
            if [[ -n "$replication_lag" ]]; then
                add_report "Replication lag from PostgreSQL:"
                while IFS='|' read -r client_addr app_name lag; do
                    [[ -z "$client_addr" ]] && continue
                    client_addr=$(echo "$client_addr" | xargs)
                    app_name=$(echo "$app_name" | xargs)
                    lag=$(echo "$lag" | xargs)
                    add_report "  - Client: $client_addr, App: $app_name, Lag: $lag"
                done <<< "$replication_lag"
            fi
        fi
    fi
    
    # Parse JSON to find members with issues
    # Check for: non-running state, unknown lag, or excessive lag
    # Default lag threshold is 100MB (104857600 bytes), can be overridden with LAG_THRESHOLD_BYTES
    local lag_threshold="${LAG_THRESHOLD_BYTES:-104857600}"
    add_report "Using lag threshold: $lag_threshold bytes ($(($lag_threshold / 1024 / 1024))MB)"
    
    # First check for non-running members
    failed_members=$(echo "$cluster_status" | jq -r '.[] | select(.State != "running") | .Member' 2>/dev/null || echo "")
    
    # If patronictl provides lag information, use it for lag-based detection
    if [[ "$has_lag_info" == "true" ]]; then
        # Convert threshold from bytes to MB for comparison (since patronictl reports in MB)
        local lag_threshold_mb=$((lag_threshold / 1024 / 1024))
        add_report "Converted lag threshold for patronictl: $lag_threshold_mb MB"
        
        local lag_failed_members=$(echo "$cluster_status" | jq -r --argjson threshold "$lag_threshold_mb" '.[] | select(.Role == "Replica" and ((.["Lag in MB"] // .Lag // .["Lag behind"]) != null and ((.["Lag in MB"] // .Lag // .["Lag behind"]) | tonumber) > $threshold)) | .Member' 2>/dev/null || echo "")
        if [[ -n "$lag_failed_members" ]]; then
            failed_members=$(echo -e "$failed_members\n$lag_failed_members" | sort -u | grep -v '^$')
        fi
    else
        add_report "Note: Lag-based member detection not available - patronictl does not provide lag information"
    fi
    
    if [[ -z "$failed_members" ]]; then
        add_report "No failed members detected - cluster appears healthy"
        return 0
    fi
    
    add_report "Failed members identified: $failed_members"
    
    # Report why each member was identified as failed
    echo "$failed_members" | while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        local member_info=$(echo "$cluster_status" | jq -r --arg member "$member" '.[] | select(.Member == $member) | "Member: \(.Member), State: \(.State), Role: \(.Role), Lag: \(.["Lag in MB"] // .Lag // .["Lag behind"] // "N/A") MB"' 2>/dev/null || echo "")
        if [[ -n "$member_info" ]]; then
            add_report "  Issue details - $member_info"
        fi
    done
    
    # Process each failed member
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        
        log "Processing failed member: $member"
        
        # Get the failed pod
        local failed_pod=""
        if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
            failed_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
                --context "$CONTEXT" \
                -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME" \
                -o jsonpath="{.items[?(@.metadata.name=='$member')].metadata.name}" 2>/dev/null || echo "")
        elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
            failed_pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" \
                --context "$CONTEXT" \
                -l "application=spilo,cluster-name=$OBJECT_NAME" \
                -o jsonpath="{.items[?(@.metadata.name=='$member')].metadata.name}" 2>/dev/null || echo "")
        fi
        
        if [[ -z "$failed_pod" ]]; then
            generate_issue "Failed pod not found" "Could not locate pod for member: $member" "error" "Check if pod exists: kubectl get pod $member -n $NAMESPACE, investigate pod status"
            continue
        fi
        
        add_report "Found failed pod: $failed_pod"
        
        # Pre-reinitialize diagnostics
        add_report "Pre-reinitialize diagnostics for $member:"
        
        # Check current replication status
        local current_repl_lag=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
            --context "$CONTEXT" -c "$container" -- \
            psql -U postgres -t -c "SELECT client_addr, application_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication WHERE application_name = '$member';" 2>/dev/null || echo "replication query failed")
        add_report "Current replication lag from leader: $current_repl_lag"
        
        # Check WAL retention on leader
        local wal_retention=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
            --context "$CONTEXT" -c "$container" -- \
            psql -U postgres -t -c "SELECT setting FROM pg_settings WHERE name = 'wal_keep_size';" 2>/dev/null || echo "unknown")
        add_report "WAL retention setting: $wal_retention"
        
        # Try patronictl reinit first
        log "Attempting to reinitialize using patronictl..."
        local reinit_output=""
        if reinit_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$failed_pod" \
            --context "$CONTEXT" -c "$container" -- \
            patronictl reinit "$patroni_cluster_name" "$member" --force 2>&1); then
            
            add_report "Successfully initiated reinitialize via patronictl for member: $member"
            add_report "Patronictl reinit output: $reinit_output"
            
            # Wait and verify the reinitialize process
            log "Waiting for reinitialize to complete..."
            sleep 30
            
            # Check if the member is now healthy and lag has improved
            local member_healthy=false
            local initial_lag=""
            local final_lag=""
            
            # Get initial lag for comparison
            initial_lag=$(echo "$cluster_status" | jq -r --arg member "$member" '.[] | select(.Member == $member) | .["Lag in MB"] // .Lag // .["Lag behind"] // "unknown"' 2>/dev/null || echo "unknown")
            add_report "Initial lag for $member: $initial_lag MB"
            
            for attempt in {1..10}; do
                if new_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
                    --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
                    
                    local member_state=$(echo "$new_status" | jq -r ".[] | select(.Member==\"$member\") | .State" 2>/dev/null || echo "")
                    final_lag=$(echo "$new_status" | jq -r --arg member "$member" '.[] | select(.Member == $member) | .["Lag in MB"] // .Lag // .["Lag behind"] // "unknown"' 2>/dev/null || echo "unknown")
                    
                    add_report "Attempt $attempt/10: Member $member state: $member_state, lag: $final_lag MB"
                    
                    if [[ "$member_state" == "running" ]]; then
                        # Check if lag has significantly improved (less than 10% of original or under threshold)
                        if [[ "$initial_lag" != "unknown" && "$final_lag" != "unknown" && "$initial_lag" != "0" ]]; then
                            local lag_improvement_threshold=$((initial_lag / 10))  # 90% improvement
                            local absolute_threshold=$((lag_threshold_mb))
                            
                            if [[ $(echo "$final_lag" | bc 2>/dev/null || echo "$final_lag") -lt $lag_improvement_threshold ]] || [[ $(echo "$final_lag" | bc 2>/dev/null || echo "$final_lag") -lt $absolute_threshold ]]; then
                                add_report "Member $member successfully reinitialized: lag improved from $initial_lag MB to $final_lag MB"
                                member_healthy=true
                                break
                            else
                                add_report "Member $member is running but lag hasn't improved significantly: $initial_lag MB -> $final_lag MB"
                            fi
                        else
                            add_report "Member $member is running (lag comparison not available)"
                            member_healthy=true
                            break
                        fi
                    fi
                fi
                log "Attempt $attempt/10: Member $member not yet healthy, waiting..."
                sleep 30
            done
            
            if [[ "$member_healthy" == "false" ]]; then
                if [[ "$final_lag" != "unknown" && "$initial_lag" != "unknown" ]]; then
                    generate_issue "Reinitialize failed to improve lag" "Member $member lag: $initial_lag MB -> $final_lag MB. May need manual intervention." "error" "Consider manual basebackup or pod recreation: kubectl delete pod $member -n $NAMESPACE, or investigate underlying replication issues"
                    
                    # Add diagnostic information
                    add_report "Diagnosing reinitialize failure for $member..."
                    
                    # Check disk space on the failed pod
                    local disk_usage=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$failed_pod" \
                        --context "$CONTEXT" -c "$container" -- \
                        df -h /pgdata 2>/dev/null | tail -1 || echo "disk check failed")
                    add_report "Disk usage on $failed_pod: $disk_usage"
                    
                    # Check PostgreSQL logs for errors
                    local pg_errors=$(${KUBERNETES_DISTRIBUTION_BINARY} logs -n "$NAMESPACE" "$failed_pod" \
                        --context "$CONTEXT" -c "$container" --tail=50 | \
                        grep -i "error\|fatal\|panic\|could not\|failed" | tail -5 || echo "no recent errors found")
                    add_report "Recent PostgreSQL errors on $failed_pod: $pg_errors"
                    
                    # Check replication connection status
                    local repl_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$failed_pod" \
                        --context "$CONTEXT" -c "$container" -- \
                        psql -U postgres -t -c "SELECT state, sync_state FROM pg_stat_wal_receiver;" 2>/dev/null || echo "replication status check failed")
                    add_report "Replication status on $failed_pod: $repl_status"
                    
                    # Suggest remediation steps based on diagnosis
                    add_report "Suggested remediation steps for $member:"
                    if echo "$disk_usage" | grep -q "100%\|9[0-9]%"; then
                        add_report "  - CRITICAL: Disk space is critically low. Free up space or expand storage."
                    fi
                    if echo "$pg_errors" | grep -qi "could not receive data from WAL stream"; then
                        add_report "  - WAL streaming issue detected. Check network connectivity and WAL retention."
                    fi
                    if echo "$pg_errors" | grep -qi "requested WAL segment.*has already been removed"; then
                        add_report "  - WAL segments missing. Consider increasing wal_keep_size or using WAL archiving."
                    fi
                    if [[ "$final_lag" != "unknown" && "$initial_lag" != "unknown" ]] && [[ $final_lag -eq $initial_lag ]]; then
                        add_report "  - Lag unchanged. Consider manual basebackup: pg_basebackup or pod recreation."
                    fi
                    add_report "  - Manual intervention: kubectl exec $failed_pod -c $container -- patronictl reinit $OBJECT_NAME $member --force"
                    add_report "  - Alternative: kubectl delete pod $failed_pod -n $NAMESPACE"
                    
                else
                    generate_issue "Reinitialize incomplete" "Member $member may still be recovering or needs manual intervention" "warning" "Monitor member recovery: kubectl exec <pod> -c database -- patronictl list, wait for member to become healthy or investigate further"
                fi
            fi
        else
            # Patronictl reinit failed - analyze why and generate proper issue
            add_report "Patronictl reinit failed for member: $member"
            add_report "Patronictl reinit error output: $reinit_output"
            
            # Analyze the failure reason
            local failure_reason="Unknown"
            if echo "$reinit_output" | grep -qi "not a member of cluster"; then
                failure_reason="Cluster name mismatch - using wrong cluster name for patronictl commands"
            elif echo "$reinit_output" | grep -qi "already running"; then
                failure_reason="Member is already running - may need manual intervention"
            elif echo "$reinit_output" | grep -qi "connection.*refused\|could not connect"; then
                failure_reason="Connection failed - member may be down or network issue"
            elif echo "$reinit_output" | grep -qi "timeline.*mismatch\|diverged"; then
                failure_reason="Timeline divergence - requires manual basebackup"
            elif echo "$reinit_output" | grep -qi "wal.*not found\|missing.*segment"; then
                failure_reason="WAL segments missing - increase wal_keep_size or use archiving"
            elif echo "$reinit_output" | grep -qi "disk.*full\|no space"; then
                failure_reason="Disk space issue - free up space"
            elif echo "$reinit_output" | grep -qi "permission denied\|access denied"; then
                failure_reason="Permission issue - check PostgreSQL user permissions"
            fi
            
            generate_issue "Patronictl reinit failed" "Member $member reinitialize failed: $failure_reason. Output: $reinit_output" "error" "Follow the specific remediation steps provided in the operation report, or try manual reinit: kubectl exec <pod> -c database -- patronictl reinit <cluster> <member> --force"
            
            # Provide specific remediation steps based on failure analysis
            add_report "Recommended remediation steps for $failure_reason:"
            
            case "$failure_reason" in
                *"Cluster name mismatch"*)
                    add_report "  1. Use correct cluster name: kubectl exec $failed_pod -c $container -- patronictl reinit $patroni_cluster_name $member --force"
                    add_report "  2. Verify cluster name: kubectl exec $failed_pod -c $container -- patronictl list"
                    add_report "  3. Check Patroni configuration for cluster name settings"
                    ;;
                *"Timeline divergence"*)
                    add_report "  1. Stop the replica: kubectl exec $failed_pod -c $container -- patronictl pause $patroni_cluster_name"
                    add_report "  2. Perform manual basebackup from leader"
                    add_report "  3. Restart with clean data: kubectl exec $failed_pod -c $container -- patronictl resume $patroni_cluster_name"
                    ;;
                *"WAL segments missing"*)
                    add_report "  1. Increase WAL retention: ALTER SYSTEM SET wal_keep_size = '10GB';"
                    add_report "  2. Configure WAL archiving for better recovery"
                    add_report "  3. Consider pg_rewind if timelines are compatible"
                    ;;
                *"Disk space"*)
                    add_report "  1. Free up disk space: kubectl exec $failed_pod -c $container -- df -h"
                    add_report "  2. Clean old WAL files if safe: kubectl exec $failed_pod -c $container -- find /pgdata -name 'pg_wal/*' -mtime +1"
                    add_report "  3. Expand storage if needed"
                    ;;
                *"Connection failed"*)
                    add_report "  1. Check network connectivity between pods"
                    add_report "  2. Verify PostgreSQL is running: kubectl exec $failed_pod -c $container -- pg_isready"
                    add_report "  3. Check firewall/security group rules"
                    ;;
                *"Permission"*)
                    add_report "  1. Check PostgreSQL user permissions"
                    add_report "  2. Verify replication user exists: kubectl exec $failed_pod -c $container -- psql -U postgres -c '\\du'"
                    add_report "  3. Check pg_hba.conf for replication entries"
                    ;;
                *)
                    add_report "  1. Check detailed logs: kubectl logs $failed_pod -c $container --tail=100"
                    add_report "  2. Check member status: kubectl exec $failed_pod -c $container -- patronictl list"
                    add_report "  3. Try manual reinit with verbose output: kubectl exec $failed_pod -c $container -- patronictl reinit $patroni_cluster_name $member --force"
                    add_report "  4. Consider pg_rewind if timelines are compatible"
                    ;;
            esac
            
            add_report "IMPORTANT: Pod recreation/deletion will NOT fix replication lag issues"
            add_report "Root cause must be addressed through proper PostgreSQL replication troubleshooting"
        fi
    done <<< "$failed_members"
    
    # Final cluster status check
    log "Performing final cluster status check..."
    if final_status=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$running_pod" \
        --context "$CONTEXT" -c "$container" -- patronictl list -f json 2>/dev/null); then
        add_report "Final cluster status: $(echo "$final_status" | jq -c '.')"
        
        # Check if any members still have excessive lag after all operations
        local still_failed_members=$(echo "$final_status" | jq -r --argjson threshold "$lag_threshold_mb" '.[] | select(.Role == "Replica" and ((.["Lag in MB"] // .Lag // .["Lag behind"]) != null and ((.["Lag in MB"] // .Lag // .["Lag behind"]) | tonumber) > $threshold)) | .Member' 2>/dev/null || echo "")
        
        if [[ -n "$still_failed_members" ]]; then
            add_report "WARNING: Members still have excessive lag after operations: $still_failed_members"
            echo "$still_failed_members" | while IFS= read -r member; do
                [[ -z "$member" ]] && continue
                local final_member_lag=$(echo "$final_status" | jq -r --arg member "$member" '.[] | select(.Member == $member) | .["Lag in MB"] // .Lag // .["Lag behind"] // "unknown"' 2>/dev/null || echo "unknown")
                generate_issue "Member still has excessive lag" "Member $member has $final_member_lag MB lag after reinitialize operations. Manual intervention required." "error" "Consider manual basebackup, increase WAL retention, or investigate network/storage issues causing persistent lag"
            done
        else
            add_report "All cluster members are now within acceptable lag thresholds"
        fi
    fi
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
        "reinitialize")
            reinitialize_failed_members
            ;;
        *)
            generate_issue "Unknown operation" "Operation '$operation' is not supported" "error" "Use a supported operation: overview, failover, restart, replication, or reinitialize"
            return 1
            ;;
    esac
}

# Execute main function
main

# Generate output report to stdout (captured by Robot Framework)
echo "PostgreSQL Cluster Operations Report"
echo "===================================="
echo "Cluster: $OBJECT_NAME"
echo "Namespace: $NAMESPACE"
echo "Operation: ${OPERATION:-overview}"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "Operation Reports:"
for report in "${OPERATION_REPORTS[@]}"; do
    echo "- $report"
done

echo ""
echo "Issues:"
echo "["
for issue in "${ISSUES[@]}"; do
    echo "$issue,"
done | sed '$ s/,$//'
echo "]"

log "Cluster operations completed"

# Exit with error code if there were critical issues
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        if echo "$issue" | grep -q '"severity": "error"'; then
            exit 1
        fi
    done
fi

exit 0

