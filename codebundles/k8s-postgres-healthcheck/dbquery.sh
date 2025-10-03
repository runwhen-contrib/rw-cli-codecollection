#!/bin/bash

# Arrays to collect reports and issues
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

QUERY_REPORTS=()
ISSUES=()

# Function to sanitize a string for JSON compatibility
sanitize_string() {
  echo "$1" | sed 's/["]/ /g' | tr '\n' ' ' | tr '\r' ' '
}


# Function to generate an issue in JSON format and add to ISSUES array
generate_issue() {
  local description=$(sanitize_string "$1")
  local query=$(sanitize_string "$2")
  local error=$(sanitize_string "$3")

  issue=$(cat <<EOF
{
  "title": "Health Query Issue",
  "description": "$1",
  "description": "$description",
  "query": "$query",
  "error": "$error"
}
EOF
)
  ISSUES+=("$issue")
}

# Function to execute health queries for CrunchyDB PostgreSQL Operator
execute_crunchy_queries() {
  POD_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l postgres-operator.crunchydata.com/role=master -o jsonpath="{.items[0].metadata.name}")
  
  while IFS= read -r query; do
    echo "Executing query: $query"
    result=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" --container "$DATABASE_CONTAINER" -- bash -c "psql -U postgres -c \"$query\"" 2>&1)
    if [ $? -eq 0 ]; then
      echo "Query executed successfully."
      QUERY_REPORTS+=("Query: $query\nResult:\n$result\n")
    else
      echo "Query execution failed."
      generate_issue "Failed to execute health query" "$query" "$result"
    fi
  done <<< "$HEALTH_QUERIES"
}

# Function to execute health queries for Zalando PostgreSQL Operator
execute_zalando_queries() {
  POD_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l application=spilo -o jsonpath="{.items[0].metadata.name}")
  
  while IFS= read -r query; do
    echo "Executing query: $query"
    result=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" --container "$DATABASE_CONTAINER" -- bash -c "psql -U postgres -c \"$query\"" 2>&1)
    if [ $? -eq 0 ]; then
      echo "Query executed successfully."
      QUERY_REPORTS+=("Query: $query\nResult:\n$result\n")
    else
      echo "Query execution failed."
      generate_issue "Failed to execute health query" "$query" "$result"
    fi
  done <<< "$HEALTH_QUERIES"
}

HEALTH_QUERIES=$QUERY

if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
  execute_crunchy_queries
elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
  execute_zalando_queries
else
  echo "Unsupported API version. Please specify a valid API version containing 'crunchydata.com' or 'zalan.do'."
fi

# Print the query reports and issues
OUTPUT_FILE="../health_query_report.out"

echo "Health Query Report:" > "$OUTPUT_FILE"
for report in "${QUERY_REPORTS[@]}"; do
  echo -e "$report" >> "$OUTPUT_FILE"
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

echo "Health query report and issues have been written to $OUTPUT_FILE."
