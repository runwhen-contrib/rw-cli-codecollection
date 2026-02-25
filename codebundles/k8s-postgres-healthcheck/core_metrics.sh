#!/bin/bash

# Core Metrics Health Check Script for Kubernetes PostgreSQL Clusters
# Checks storage utilization, database sizes, and other key metrics

set -uo pipefail

# Arrays to collect reports and issues
METRICS_REPORTS=()
ISSUES=()

# Severity levels
SEV_INFO=4
SEV_WARNING=3
SEV_ERROR=2
SEV_CRITICAL=1

# Default thresholds
STORAGE_WARNING_THRESHOLD="${STORAGE_WARNING_THRESHOLD:-80}"
STORAGE_CRITICAL_THRESHOLD="${STORAGE_CRITICAL_THRESHOLD:-90}"

# Function to generate an issue in JSON format
generate_issue() {
  local title="$1"
  local description="$2"
  local severity="$3"
  local next_steps="${4:-Investigate the issue}"
  
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
  METRICS_REPORTS+=("$message")
}

# Function to find a suitable pod to run queries from
find_query_pod() {
  local pod_name=""
  local container=""
  
  if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
    container="database"
    # For metrics, prefer primary as it has the most accurate data
    pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
      -l "postgres-operator.crunchydata.com/cluster=$OBJECT_NAME,postgres-operator.crunchydata.com/role=master" \
      --field-selector=status.phase=Running \
      -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    
  elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
    container="postgres"
    pod_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" \
      -l "application=spilo,cluster-name=$OBJECT_NAME,spilo-role=master" \
      --field-selector=status.phase=Running \
      -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
  fi
  
  echo "$pod_name|$container"
}

# Function to convert bytes to human readable
human_readable() {
  local bytes=$1
  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    echo "$bytes"
    return
  fi
  
  if (( bytes >= 1099511627776 )); then
    echo "$(( bytes / 1099511627776 )) TB"
  elif (( bytes >= 1073741824 )); then
    echo "$(( bytes / 1073741824 )) GB"
  elif (( bytes >= 1048576 )); then
    echo "$(( bytes / 1048576 )) MB"
  elif (( bytes >= 1024 )); then
    echo "$(( bytes / 1024 )) KB"
  else
    echo "$bytes B"
  fi
}

# Main core metrics check function
check_core_metrics() {
  add_report "=== PostgreSQL Core Metrics Health Check ==="
  add_report "Cluster: $OBJECT_NAME | Namespace: $NAMESPACE"
  add_report "Storage Warning Threshold: ${STORAGE_WARNING_THRESHOLD}% | Critical: ${STORAGE_CRITICAL_THRESHOLD}%"
  add_report ""
  
  # Find the primary pod
  local pod_info=$(find_query_pod)
  local pod_name=$(echo "$pod_info" | cut -d'|' -f1)
  local container=$(echo "$pod_info" | cut -d'|' -f2)
  
  if [[ -z "$pod_name" ]]; then
    generate_issue \
      "No Running Primary Pod for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Could not find a running primary PostgreSQL pod to check metrics." \
      $SEV_ERROR \
      "Verify the cluster is running: kubectl get pods -n $NAMESPACE"
    add_report "ERROR: No running primary pod found for cluster $OBJECT_NAME"
    return 1
  fi
  
  add_report "Using pod: $pod_name (container: $container)"
  add_report ""
  
  # =====================================
  # Storage Utilization (Filesystem Level)
  # =====================================
  add_report "--- Filesystem Storage Utilization ---"
  
  # Check data directory storage
  local df_output=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- df -h 2>/dev/null | grep -E "pgdata|postgres|/home" | head -5)
  
  if [[ -n "$df_output" ]]; then
    add_report "Filesystem usage:"
    add_report "Filesystem           Size  Used  Avail Use% Mounted on"
    while read -r line; do
      add_report "$line"
      
      # Extract usage percentage and check thresholds
      local usage_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
      local mount_point=$(echo "$line" | awk '{print $6}')
      
      if [[ "$usage_pct" =~ ^[0-9]+$ ]]; then
        if (( usage_pct >= STORAGE_CRITICAL_THRESHOLD )); then
          generate_issue \
            "Critical Storage Utilization for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
            "Filesystem $mount_point is at ${usage_pct}% capacity. Database may become read-only or crash." \
            $SEV_CRITICAL \
            "Immediately free up space: 1) Remove old WAL files if safe, 2) VACUUM FULL large tables, 3) Expand storage volume, 4) Archive or delete old data"
        elif (( usage_pct >= STORAGE_WARNING_THRESHOLD )); then
          generate_issue \
            "High Storage Utilization for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
            "Filesystem $mount_point is at ${usage_pct}% capacity." \
            $SEV_WARNING \
            "Plan for storage expansion: 1) Monitor growth rate, 2) Consider archiving old data, 3) Run VACUUM to reclaim space"
        fi
      fi
    done < <(echo "$df_output")
  else
    add_report "Could not retrieve filesystem usage information"
  fi
  
  # Get detailed storage from PostgreSQL data directory
  local data_dir_size=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- du -sh /pgdata 2>/dev/null | awk '{print $1}' || echo "unknown")
  add_report ""
  add_report "PostgreSQL data directory size: $data_dir_size"
  
  # =====================================
  # Database Sizes
  # =====================================
  add_report ""
  add_report "--- Database Sizes ---"
  
  local db_sizes=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        datname as database,
        pg_size_pretty(pg_database_size(datname)) as size,
        pg_database_size(datname) as size_bytes
      FROM pg_database 
      WHERE datistemplate = false 
      ORDER BY pg_database_size(datname) DESC;" 2>/dev/null)
  
  if [[ -n "$db_sizes" ]]; then
    add_report "Database             | Size"
    add_report "---------------------|------------"
    while IFS='|' read -r db size size_bytes; do
      [[ -z "$db" ]] && continue
      db=$(echo "$db" | xargs)
      size=$(echo "$size" | xargs)
      add_report "$(printf "%-20s | %s" "$db" "$size")"
    done < <(echo "$db_sizes")
  fi
  
  # Total database size
  local total_db_size=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d ' \n')
  add_report ""
  add_report "Total database size: $total_db_size"
  
  # =====================================
  # Table Sizes (Top 10 largest)
  # =====================================
  add_report ""
  add_report "--- Largest Tables (Top 10) ---"
  
  local table_sizes=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        schemaname || '.' || relname as table_name,
        pg_size_pretty(pg_total_relation_size(relid)) as total_size,
        pg_size_pretty(pg_relation_size(relid)) as table_size,
        pg_size_pretty(pg_indexes_size(relid)) as index_size
      FROM pg_catalog.pg_statio_user_tables
      ORDER BY pg_total_relation_size(relid) DESC
      LIMIT 10;" 2>/dev/null)
  
  if [[ -n "$table_sizes" ]]; then
    add_report "Table                          | Total    | Table    | Indexes"
    add_report "-------------------------------|----------|----------|--------"
    while IFS='|' read -r tbl total tsize isize; do
      [[ -z "$tbl" ]] && continue
      tbl=$(echo "$tbl" | xargs)
      total=$(echo "$total" | xargs)
      tsize=$(echo "$tsize" | xargs)
      isize=$(echo "$isize" | xargs)
      add_report "$(printf "%-30s | %-8s | %-8s | %s" "$tbl" "$total" "$tsize" "$isize")"
    done < <(echo "$table_sizes")
  fi
  
  # =====================================
  # WAL Storage
  # =====================================
  add_report ""
  add_report "--- WAL (Write-Ahead Log) Storage ---"
  
  local wal_size=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- du -sh /pgdata/pg*/pg_wal 2>/dev/null | awk '{print $1}' || echo "unknown")
  add_report "WAL directory size: $wal_size"
  
  local wal_count=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- ls -1 /pgdata/pg*/pg_wal 2>/dev/null | wc -l || echo "unknown")
  add_report "WAL file count: $wal_count"
  
  # WAL settings
  local wal_keep=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SHOW wal_keep_size;" 2>/dev/null | tr -d ' \n')
  local max_wal=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "SHOW max_wal_size;" 2>/dev/null | tr -d ' \n')
  add_report "WAL keep size: ${wal_keep:-unknown}"
  add_report "Max WAL size: ${max_wal:-unknown}"
  
  # =====================================
  # Table Bloat Estimation
  # =====================================
  add_report ""
  add_report "--- Table Bloat Estimation ---"
  
  local bloat_check=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        schemaname || '.' || relname as table_name,
        n_dead_tup as dead_tuples,
        n_live_tup as live_tuples,
        CASE WHEN n_live_tup > 0 
          THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1)
          ELSE 0 
        END as dead_pct
      FROM pg_stat_user_tables
      WHERE n_dead_tup > 10000
      ORDER BY n_dead_tup DESC
      LIMIT 10;" 2>/dev/null)
  
  if [[ -n "$bloat_check" && ! "$bloat_check" =~ ^[[:space:]]*$ ]]; then
    add_report "Tables with significant dead tuples (may need VACUUM):"
    add_report "Table                          | Dead Tuples | Live Tuples | Dead %"
    add_report "-------------------------------|-------------|-------------|-------"
    while IFS='|' read -r tbl dead live pct; do
      [[ -z "$tbl" ]] && continue
      tbl=$(echo "$tbl" | xargs)
      dead=$(echo "$dead" | xargs)
      live=$(echo "$live" | xargs)
      pct=$(echo "$pct" | xargs)
      add_report "$(printf "%-30s | %11s | %11s | %s%%" "$tbl" "$dead" "$live" "$pct")"
      
      # Generate issue for high bloat
      if [[ "$pct" =~ ^[0-9]+\.?[0-9]*$ ]] && (( ${pct%.*} >= 30 )); then
        generate_issue \
          "High Table Bloat Detected for \`$tbl\` in Postgres Cluster \`$OBJECT_NAME\`" \
          "Table $tbl has ${pct}% dead tuples ($dead dead / $live live). This wastes storage and slows queries." \
          $SEV_WARNING \
          "Run VACUUM ANALYZE $tbl or consider VACUUM FULL during maintenance window"
      fi
    done < <(echo "$bloat_check")
  else
    add_report "No tables with significant bloat detected"
  fi
  
  # =====================================
  # Index Health
  # =====================================
  add_report ""
  add_report "--- Index Health ---"
  
  # Check for unused indexes
  local unused_indexes=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        schemaname || '.' || relname as table_name,
        indexrelname as index_name,
        pg_size_pretty(pg_relation_size(indexrelid)) as index_size
      FROM pg_stat_user_indexes
      WHERE idx_scan = 0
        AND pg_relation_size(indexrelid) > 1048576
      ORDER BY pg_relation_size(indexrelid) DESC
      LIMIT 5;" 2>/dev/null)
  
  if [[ -n "$unused_indexes" && ! "$unused_indexes" =~ ^[[:space:]]*$ ]]; then
    add_report "Unused indexes (>1MB, never scanned):"
    echo "$unused_indexes" | while IFS='|' read -r tbl idx size; do
      [[ -z "$tbl" ]] && continue
      tbl=$(echo "$tbl" | xargs)
      idx=$(echo "$idx" | xargs)
      size=$(echo "$size" | xargs)
      add_report "  $idx on $tbl ($size)"
    done
    
    generate_issue \
      "Unused Indexes Detected in Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "Found indexes that have never been used. These waste storage and slow down writes." \
      $SEV_INFO \
      "Review unused indexes and consider dropping them to save space and improve write performance"
  else
    add_report "No unused indexes detected"
  fi
  
  # =====================================
  # Temporary File Usage
  # =====================================
  add_report ""
  add_report "--- Temporary File Usage ---"
  
  local temp_files=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        datname,
        temp_files,
        pg_size_pretty(temp_bytes) as temp_size
      FROM pg_stat_database
      WHERE temp_files > 0
      ORDER BY temp_bytes DESC
      LIMIT 5;" 2>/dev/null)
  
  if [[ -n "$temp_files" && ! "$temp_files" =~ ^[[:space:]]*$ ]]; then
    add_report "Databases using temporary files (may indicate need for more work_mem):"
    echo "$temp_files" | while IFS='|' read -r db files size; do
      [[ -z "$db" ]] && continue
      db=$(echo "$db" | xargs)
      files=$(echo "$files" | xargs)
      size=$(echo "$size" | xargs)
      add_report "  $db: $files files, $size total"
    done
  else
    add_report "No significant temporary file usage detected"
  fi
  
  # =====================================
  # Checkpoint and Background Writer Stats
  # =====================================
  add_report ""
  add_report "--- Checkpoint Statistics ---"
  
  local checkpoint_stats=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$pod_name" --context "$CONTEXT" -c "$container" \
    -- psql -U postgres -t -c "
      SELECT 
        checkpoints_timed,
        checkpoints_req,
        buffers_checkpoint,
        buffers_clean,
        buffers_backend
      FROM pg_stat_bgwriter;" 2>/dev/null)
  
  if [[ -n "$checkpoint_stats" ]]; then
    echo "$checkpoint_stats" | while IFS='|' read -r timed req buf_cp buf_clean buf_back; do
      [[ -z "$timed" ]] && continue
      timed=$(echo "$timed" | xargs)
      req=$(echo "$req" | xargs)
      buf_cp=$(echo "$buf_cp" | xargs)
      buf_clean=$(echo "$buf_clean" | xargs)
      buf_back=$(echo "$buf_back" | xargs)
      
      add_report "Timed checkpoints: $timed"
      add_report "Requested checkpoints: $req"
      add_report "Buffers written (checkpoint): $buf_cp"
      add_report "Buffers written (bgwriter): $buf_clean"
      add_report "Buffers written (backends): $buf_back"
      
      # Check if backends are writing too many buffers (indicates shared_buffers too small)
      if [[ "$buf_back" =~ ^[0-9]+$ && "$buf_cp" =~ ^[0-9]+$ && "$buf_cp" -gt 0 ]]; then
        local backend_ratio=$((buf_back * 100 / (buf_cp + buf_clean + buf_back + 1)))
        if (( backend_ratio > 20 )); then
          generate_issue \
            "High Backend Buffer Writes in Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
            "Backends are writing ${backend_ratio}% of buffers directly. This indicates shared_buffers may be too small." \
            $SEV_WARNING \
            "Consider increasing shared_buffers configuration parameter"
        fi
      fi
    done
  fi
  
  add_report ""
  add_report "=== Core Metrics Health Check Complete ==="
}

# Main execution
check_core_metrics

# Generate output report
OUTPUT_FILE="../core_metrics_report.out"

echo "Core Metrics Health Report:" > "$OUTPUT_FILE"
for report in "${METRICS_REPORTS[@]}"; do
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

echo "Core metrics report written to $OUTPUT_FILE"
