#!/bin/bash

# Set the maximum acceptable age of the backup (in seconds) - here it's 1 day (86400 seconds)
MAX_AGE=86400

# Arrays to collect reports and issues
CONFIG_REPORTS=()
ISSUES=()

# Function to generate an issue in JSON format and add to ISSUES array
generate_issue() {
  issue=$(cat <<EOF
{
  "title": "Configuration issue for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`",
  "description": "$1",
  "parameter": "$2",
  "current_value": "$3",
  "expected_value": "$4"
}
EOF
)
  ISSUES+=("$issue")
}

# Function to display configuration and perform sanity checks for CrunchyDB PostgreSQL Operator
display_crunchy_config() {
  POD_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l postgres-operator.crunchydata.com/role=master -o jsonpath="{.items[0].metadata.name}")
  
  CONFIG=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -- psql -U postgres -c "SHOW ALL")
  
  echo "CrunchyDB PostgreSQL Configuration:"
  echo "$CONFIG"

  CONFIG_REPORTS+=("CrunchyDB PostgreSQL Configuration:\n$CONFIG")

  # Sanity Checks
  echo "Performing sanity checks..."
  if [[ "$CONFIG" == *"shared_buffers"* ]]; then
    echo "shared_buffers setting is present."
  else
    generate_issue "Missing critical configuration parameter" "shared_buffers" "None" "Expected to be present"
  fi

  if [[ "$CONFIG" == *"max_connections"* ]]; then
    echo "max_connections setting is present."
  else
    generate_issue "Missing critical configuration parameter" "max_connections" "None" "Expected to be present"
  fi

  # Example additional sanity check for max_connections
  MAX_CONNECTIONS=$(echo "$CONFIG" | grep -i max_connections | awk '{print $3}')
  if (( MAX_CONNECTIONS < 100 )); then
    generate_issue "max_connections is set to less than 100" "max_connections" "$MAX_CONNECTIONS" ">= 100"
  else
    echo "max_connections setting is adequate."
  fi
}

# Function to display configuration and perform sanity checks for Zalando PostgreSQL Operator
display_zalando_config() {
  POD_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l application=spilo -o jsonpath="{.items[0].metadata.name}")
  
  CONFIG=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -- psql -U postgres -c "SHOW ALL")
  
  echo "Zalando PostgreSQL Configuration:"
  echo "$CONFIG" &2>1

  CONFIG_REPORTS+=("Zalando PostgreSQL Configuration:\n$CONFIG")

  # Sanity Checks
  echo "Performing sanity checks..."
  if [[ "$CONFIG" == *"shared_buffers"* ]]; then
    echo "shared_buffers setting is present."
  else
    generate_issue "Missing critical configuration parameter" "shared_buffers" "None" "Expected to be present"
  fi

  if [[ "$CONFIG" == *"max_connections"* ]]; then
    echo "max_connections setting is present."
  else
    generate_issue "Missing critical configuration parameter" "max_connections" "None" "Expected to be present"
  fi

  # Example additional sanity check for max_connections
  MAX_CONNECTIONS=$(echo "$CONFIG" | grep -i max_connections | awk '{print $3}')
  if (( MAX_CONNECTIONS < 100 )); then
    generate_issue "max_connections is set to less than 100" "max_connections" "$MAX_CONNECTIONS" ">= 100"
  else
    echo "max_connections setting is adequate."
  fi
}

if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
  display_crunchy_config
elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
  display_zalando_config
else
  echo "Unsupported API version. Please specify a valid API version containing 'crunchydata.com' or 'zalan.do'."
fi

# Print the configuration reports and issues
OUTPUT_FILE="../config_report.out"

echo "Configuration Report:" > "$OUTPUT_FILE"
for report in "${CONFIG_REPORTS[@]}"; do
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

echo "Configuration report and issues have been written to $OUTPUT_FILE."
