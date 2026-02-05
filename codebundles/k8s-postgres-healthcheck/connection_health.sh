#!/bin/bash

# Connection Health Check Script for Kubernetes PostgreSQL Clusters
# Checks connection utilization, client summaries, and connection saturation
# Prefers replicas for read-only queries to minimize impact on primary

set -uo pipefail

# Arrays to collect reports and issues
CONNECTION_REPORTS=()
ISSUES=()

# Severity levels
SEV_INFO=4
SEV_WARNING=3
SEV_ERROR=2
SEV_CRITICAL=1

# Function to generate an issue in JSON format
generate_issue() {
  local title="$1"
  local description="$2"
  local severity="$3"
  local next_steps="${4:-Investigate the connection issue}"
  
  local issue
  issue=$(jq -n \
    --arg title "$title" \
    --arg description "$description" \
    --argjson severity "$severity" \
    --arg cluster "$OBJECT_NAME" \
    --arg namespace "$NAMESPACE" \
    --arg next_steps "$next_steps" \
    '{title: $title, description: $description, severity: $severity, cluster: $cluster, namespace: $namespace, next_steps: $next_steps}')
  ISSUES+=("$issue")
}

# Function to add report entry
add_report() {
  local message="$1"
  echo "$message"
  CONNECTION_REPORTS+=("$message")
}

# Function to find a suitable pod to run queries from
# Prefers replicas for read-only queries to minimize primary load
find_query_pod() {
  local prefer_replica="${1:-true}"
  local pod_name=""
  local container=""
  local role=""
  
  if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
    container="database"
    
    if [[ "$prefer_replica" == "true" ]]; then
      # Try to find a replica first
      pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
        -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/role=replica" \
        --field-selector=status.phase=Running \
        -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
      
      if [[ -n "$pod_name" ]]; then
        role="replica"
      fi
    fi
    
    # Fall back to primary if no replica or replica not preferred
    if [[ -z "$pod_name" ]]; then
      pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
        -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/role=master" \
        --field-selector=status.phase=Running \
        -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
      role="primary"
    fi
    
  elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
    container="postgres"
    
    if [[ "$prefer_replica" == "true" ]]; then
      # Try to find a replica first
      pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
        -l "application=spilo,cluster-name=$OBJECT_NAME,spilo-role=replica" \
        --field-selector=status.phase=Running \
        -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
      
      if [[ -n "$pod_name" ]]; then
        role="replica"
      fi
    fi
    
    # Fall back to primary if no replica or replica not preferred
    if [[ -z "$pod_name" ]]; then
      pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
        -l "application=spilo,cluster-name=$OBJECT_NAME,spilo-role=master" \
        --field-selector=status.phase=Running \
        -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
      role="primary"
    fi
  fi
  
  echo "$pod_name|$container|$role"
}

# Function to test database connectivity and detect connection issues
test_db_connection() {
  local pod_name="$1"
  local container="$2"
  
  # Try a simple query to test connectivity
  local result=""
  local exit_code=0
  
  result=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SELECT 1;" 2>&1) || exit_code=$?
  
  if [[ $exit_code -ne 0 ]]; then
    # Analyze the error
    if echo "$result" | grep -qi "too many connections\|connection limit\|FATAL.*sorry.*too many"; then
      generate_issue \
        "Connection Saturation for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
        "Database is rejecting connections due to connection saturation. Max connections limit has been reached." \
        $SEV_CRITICAL \
        "Immediately investigate connection leaks, kill idle connections, or increase max_connections. Consider implementing connection pooling with PgBouncer."
      add_report "CRITICAL: Database is rejecting connections - connection limit reached"
      return 1
    elif echo "$result" | grep -qi "permission denied\|authentication failed\|password\|no pg_hba.conf"; then
      generate_issue \
        "Database Connection Permission Issue for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
        "Could not connect to database due to permission or authentication issues: $result" \
        $SEV_INFO \
        "Check database credentials and pg_hba.conf configuration. Verify the postgres user has appropriate permissions."
      add_report "INFO: Connection test failed due to permissions - $result"
      return 2
    else
      generate_issue \
        "Database Connection Failed for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
        "Could not connect to database: $result" \
        $SEV_ERROR \
        "Investigate database connectivity. Check if PostgreSQL is running and accepting connections."
      add_report "ERROR: Connection test failed - $result"
      return 3
    fi
  fi
  
  return 0
}

# Main connection health check function
check_connection_health() {
  local threshold="${CONNECTION_UTILIZATION_THRESHOLD:-80}"
  local critical_threshold=$((threshold + 10))
  
  add_report "=== PostgreSQL Connection Health Check ==="
  add_report "Cluster: $OBJECT_NAME | Namespace: $NAMESPACE"
  add_report "Warning Threshold: ${threshold}% | Critical Threshold: ${critical_threshold}%"
  add_report ""
  
  # Find a suitable pod (prefer replica for read-only queries)
  local pod_info=$(find_query_pod "true")
  local pod_name=$(echo "$pod_info" | cut -d'|' -f1)
  local container=$(echo "$pod_info" | cut -d'|' -f2)
  local role=$(echo "$pod_info" | cut -d'|' -f3)
  
  if [[ -z "$pod_name" ]]; then
    generate_issue \
      "No Running Pods Found for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Could not find any running PostgreSQL pods to check connection health." \
      $SEV_ERROR \
      "Verify the cluster is running: kubectl get pods -n $NAMESPACE -l postgres-operator.crunchydata.com/cluster=$OBJECT_NAME"
    add_report "ERROR: No running pods found for cluster $OBJECT_NAME"
    return 1
  fi
  
  add_report "Using pod: $pod_name (role: $role, container: $container)"
  add_report ""
  
  # Test connectivity first
  if ! test_db_connection "$pod_name" "$container"; then
    # Error already reported by test_db_connection
    return 1
  fi
  
  add_report "--- Connection Utilization ---"
  
  # Get max_connections
  local max_conn=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SHOW max_connections;" 2>/dev/null | tr -d ' \n')
  
  if [[ -z "$max_conn" || ! "$max_conn" =~ ^[0-9]+$ ]]; then
    add_report "Warning: Could not retrieve max_connections value"
    return 1
  fi
  
  # Get superuser_reserved_connections
  local reserved_conn=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SHOW superuser_reserved_connections;" 2>/dev/null | tr -d ' \n')
  reserved_conn="${reserved_conn:-3}"
  
  # Get current connections (total and by type)
  local current_conn=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' \n')
  
  local client_conn=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend';" 2>/dev/null | tr -d ' \n')
  
  # Fallback for older PostgreSQL versions without backend_type
  if [[ -z "$client_conn" || ! "$client_conn" =~ ^[0-9]+$ ]]; then
    client_conn="$current_conn"
  fi
  
  # Calculate available connections (excluding reserved)
  local available_conn=$((max_conn - reserved_conn))
  # Guard against division by zero from misconfiguration
  if [[ $max_conn -le 0 ]]; then
    max_conn=1
  fi
  if [[ $available_conn -le 0 ]]; then
    available_conn=1
  fi
  local utilization=$((current_conn * 100 / max_conn))
  local effective_utilization=$((current_conn * 100 / available_conn))
  
  add_report "Max Connections: $max_conn (reserved for superuser: $reserved_conn)"
  add_report "Available for clients: $available_conn"
  add_report "Current Total Connections: $current_conn"
  add_report "Client Backend Connections: $client_conn"
  add_report "Utilization: $utilization% (effective: $effective_utilization%)"
  add_report ""
  
  # Check thresholds and generate appropriate issues
  if (( effective_utilization >= critical_threshold )); then
    generate_issue \
      "Critical Connection Utilization for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Connection utilization is critically high at ${effective_utilization}% (${current_conn}/${available_conn} available). Database may start rejecting connections." \
      $SEV_CRITICAL \
      "Immediately investigate: 1) Check for connection leaks in applications, 2) Kill long-idle connections, 3) Implement connection pooling (PgBouncer), 4) Consider increasing max_connections"
    add_report "CRITICAL: Connection utilization at ${effective_utilization}%"
  elif (( effective_utilization >= threshold )); then
    generate_issue \
      "High Connection Utilization for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Connection utilization is high at ${effective_utilization}% (${current_conn}/${available_conn} available). Consider investigating connection usage." \
      $SEV_WARNING \
      "Investigate connection usage patterns: 1) Review application connection pooling settings, 2) Check for idle connections, 3) Consider implementing PgBouncer"
    add_report "WARNING: Connection utilization at ${effective_utilization}%"
  else
    add_report "OK: Connection utilization is healthy at ${effective_utilization}%"
  fi
  
  add_report ""
  add_report "--- Client Connection Summary ---"
  
  # Connections by application name
  add_report ""
  add_report "Connections by Application:"
  local conn_by_app=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        COALESCE(application_name, 'unknown') as app,
        count(*) as connections,
        count(*) FILTER (WHERE state = 'active') as active,
        count(*) FILTER (WHERE state = 'idle') as idle,
        count(*) FILTER (WHERE state = 'idle in transaction') as idle_in_txn
      FROM pg_stat_activity 
      WHERE backend_type = 'client backend' OR backend_type IS NULL
      GROUP BY application_name 
      ORDER BY connections DESC 
      LIMIT 10;" 2>/dev/null)
  
  if [[ -n "$conn_by_app" ]]; then
    add_report "App Name                    | Total | Active | Idle | Idle in Txn"
    add_report "----------------------------|-------|--------|------|------------"
    while IFS='|' read -r app total active idle idle_txn; do
      [[ -z "$app" ]] && continue
      app=$(echo "$app" | xargs)
      total=$(echo "$total" | xargs)
      active=$(echo "$active" | xargs)
      idle=$(echo "$idle" | xargs)
      idle_txn=$(echo "$idle_txn" | xargs)
      add_report "$(printf "%-27s | %5s | %6s | %4s | %s" "$app" "$total" "$active" "$idle" "$idle_txn")"
    done < <(echo "$conn_by_app")
  fi
  
  # Connections by user
  add_report ""
  add_report "Connections by User:"
  local conn_by_user=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        usename as username,
        count(*) as connections,
        count(*) FILTER (WHERE state = 'active') as active,
        count(*) FILTER (WHERE state = 'idle') as idle
      FROM pg_stat_activity 
      WHERE usename IS NOT NULL
      GROUP BY usename 
      ORDER BY connections DESC 
      LIMIT 10;" 2>/dev/null)
  
  if [[ -n "$conn_by_user" ]]; then
    add_report "Username             | Total | Active | Idle"
    add_report "---------------------|-------|--------|-----"
    while IFS='|' read -r user total active idle; do
      [[ -z "$user" ]] && continue
      user=$(echo "$user" | xargs)
      total=$(echo "$total" | xargs)
      active=$(echo "$active" | xargs)
      idle=$(echo "$idle" | xargs)
      add_report "$(printf "%-20s | %5s | %6s | %s" "$user" "$total" "$active" "$idle")"
    done < <(echo "$conn_by_user")
  fi
  
  # Connections by database
  add_report ""
  add_report "Connections by Database:"
  local conn_by_db=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        datname as database,
        count(*) as connections,
        count(*) FILTER (WHERE state = 'active') as active,
        count(*) FILTER (WHERE state = 'idle') as idle
      FROM pg_stat_activity 
      WHERE datname IS NOT NULL
      GROUP BY datname 
      ORDER BY connections DESC 
      LIMIT 10;" 2>/dev/null)
  
  if [[ -n "$conn_by_db" ]]; then
    add_report "Database             | Total | Active | Idle"
    add_report "---------------------|-------|--------|-----"
    while IFS='|' read -r db total active idle; do
      [[ -z "$db" ]] && continue
      db=$(echo "$db" | xargs)
      total=$(echo "$total" | xargs)
      active=$(echo "$active" | xargs)
      idle=$(echo "$idle" | xargs)
      add_report "$(printf "%-20s | %5s | %6s | %s" "$db" "$total" "$active" "$idle")"
    done < <(echo "$conn_by_db")
  fi
  
  # Connections by client address (top sources)
  add_report ""
  add_report "Connections by Client Address (Top 10):"
  local conn_by_addr=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        COALESCE(client_addr::text, 'local') as client,
        count(*) as connections,
        count(*) FILTER (WHERE state = 'active') as active,
        count(*) FILTER (WHERE state = 'idle') as idle
      FROM pg_stat_activity 
      WHERE backend_type = 'client backend' OR backend_type IS NULL
      GROUP BY client_addr 
      ORDER BY connections DESC 
      LIMIT 10;" 2>/dev/null)
  
  if [[ -n "$conn_by_addr" ]]; then
    add_report "Client Address       | Total | Active | Idle"
    add_report "---------------------|-------|--------|-----"
    while IFS='|' read -r addr total active idle; do
      [[ -z "$addr" ]] && continue
      addr=$(echo "$addr" | xargs)
      total=$(echo "$total" | xargs)
      active=$(echo "$active" | xargs)
      idle=$(echo "$idle" | xargs)
      add_report "$(printf "%-20s | %5s | %6s | %s" "$addr" "$total" "$active" "$idle")"
    done < <(echo "$conn_by_addr")
  fi
  
  # Connection state summary
  add_report ""
  add_report "Connection State Summary:"
  local conn_states=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        COALESCE(state, 'null') as state,
        count(*) as count
      FROM pg_stat_activity 
      GROUP BY state 
      ORDER BY count DESC;" 2>/dev/null)
  
  if [[ -n "$conn_states" ]]; then
    echo "$conn_states" | while IFS='|' read -r state count; do
      [[ -z "$state" ]] && continue
      state=$(echo "$state" | xargs)
      count=$(echo "$count" | xargs)
      add_report "  $state: $count"
    done
  fi
  
  # Check for problematic connection patterns
  add_report ""
  add_report "--- Connection Health Checks ---"
  
  # Check for long-running idle connections
  local long_idle=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT count(*) 
      FROM pg_stat_activity 
      WHERE state = 'idle' 
        AND state_change < NOW() - INTERVAL '30 minutes'
        AND backend_type = 'client backend';" 2>/dev/null | tr -d ' \n')
  
  if [[ -n "$long_idle" && "$long_idle" =~ ^[0-9]+$ && "$long_idle" -gt 10 ]]; then
    add_report "WARNING: Found $long_idle connections idle for more than 30 minutes"
    if (( effective_utilization >= threshold / 2 )); then
      generate_issue \
        "Long-Idle Connections Detected for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
        "Found $long_idle connections idle for more than 30 minutes while utilization is at ${effective_utilization}%." \
        $SEV_WARNING \
        "Consider: 1) Implementing connection pooling (PgBouncer), 2) Setting idle_in_transaction_session_timeout, 3) Configuring application connection pool idle timeouts"
    fi
  else
    add_report "OK: No excessive long-idle connections detected"
  fi
  
  # Check for idle in transaction connections
  local idle_in_txn=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT count(*) 
      FROM pg_stat_activity 
      WHERE state = 'idle in transaction' 
        AND state_change < NOW() - INTERVAL '5 minutes';" 2>/dev/null | tr -d ' \n')
  
  if [[ -n "$idle_in_txn" && "$idle_in_txn" =~ ^[0-9]+$ && "$idle_in_txn" -gt 0 ]]; then
    add_report "WARNING: Found $idle_in_txn connections idle in transaction for more than 5 minutes"
    generate_issue \
      "Idle-in-Transaction Connections for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Found $idle_in_txn connections in 'idle in transaction' state for more than 5 minutes. This can cause table bloat and lock issues." \
      $SEV_WARNING \
      "Investigate application transaction handling. Consider setting idle_in_transaction_session_timeout in PostgreSQL configuration."
  else
    add_report "OK: No long idle-in-transaction connections detected"
  fi
  
  # Check for waiting connections (blocked)
  local waiting=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT count(*) 
      FROM pg_stat_activity 
      WHERE wait_event_type = 'Lock';" 2>/dev/null | tr -d ' \n')
  
  if [[ -n "$waiting" && "$waiting" =~ ^[0-9]+$ && "$waiting" -gt 5 ]]; then
    add_report "WARNING: Found $waiting connections waiting on locks"
    generate_issue \
      "Lock Contention Detected for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Found $waiting connections waiting on locks. This may indicate lock contention issues." \
      $SEV_WARNING \
      "Investigate blocking queries: SELECT * FROM pg_stat_activity WHERE wait_event_type = 'Lock'"
  else
    add_report "OK: No significant lock contention detected"
  fi
  
  add_report ""
  add_report "=== Connection Health Check Complete ==="
}

# Main execution
check_connection_health

# Generate output report
OUTPUT_FILE="../connection_health_report.out"

echo "Connection Health Report:" > "$OUTPUT_FILE"
for report in "${CONNECTION_REPORTS[@]}"; do
  echo "$report" >> "$OUTPUT_FILE"
done

echo "" >> "$OUTPUT_FILE"
echo "Issues:" >> "$OUTPUT_FILE"
echo "[" >> "$OUTPUT_FILE"
for i in "${!ISSUES[@]}"; do
  if [[ $i -gt 0 ]]; then
    echo "," >> "$OUTPUT_FILE"
  fi
  echo "${ISSUES[$i]}" >> "$OUTPUT_FILE"
done
echo "]" >> "$OUTPUT_FILE"

echo "Connection health report written to $OUTPUT_FILE"
