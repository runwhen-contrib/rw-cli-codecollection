#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# ENVIRONMENT VARIABLES (Required)
#   APP_GATEWAY_NAME:   Name of the Application Gateway
#   AZ_RESOURCE_GROUP:  Name of the Resource Group containing the App Gateway
#
#
# This script:
#  1) Retrieves the App Gateway's Resource ID
#  2) Lists diagnostic settings for that resource and extracts a Log Analytics workspaceId (if configured)
#  3) Obtains the Workspace GUID (customerId) from that workspace resourceId
#  4) Queries the logs for:
#     - requests in the last hour
#     - non-ssl requests in the last hour
#     - failed requests (>=400) in the last hour
#     - errors by user agent
#     - errors by request URI
#  5) Produces a JSON summary, e.g.:
#     {
#       "requestsLastHour": 1234,
#       "nonSslRequestsLastHour": 100,
#       "failedRequestsLastHour": 50,
#       "errorsByUserAgent": [
#         { "userAgent": "Mozilla...", "count": 30 },
#         ...
#       ],
#       "errorsByUri": [
#         { "uri": "/some/url", "count": 10 },
#         ...
#       ]
#     }
# ------------------------------------------------------------------

# Validate required variables
: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

OUTPUT_FILE="app_gateway_log_metrics.json"

echo "Fetching Application Gateway resource ID..."

AGW_RESOURCE_ID=$(az network application-gateway show \
  --name "$APP_GATEWAY_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv 2>/dev/null)

if [[ -z "$AGW_RESOURCE_ID" ]]; then
  echo "ERROR: Could not fetch Application Gateway named '$APP_GATEWAY_NAME' in resource group '$AZ_RESOURCE_GROUP'."
  exit 1
fi

echo "Discovered App Gateway Resource ID: $AGW_RESOURCE_ID"

# ------------------------------------------------------------------
# 1) Determine if there's a Diagnostic Setting sending logs to Log Analytics
# ------------------------------------------------------------------
echo "Checking diagnostic settings for the App Gateway..."

DIAG_SETTINGS_JSON=$(az monitor diagnostic-settings list --resource "$AGW_RESOURCE_ID" -o json)
if [[ "$DIAG_SETTINGS_JSON" == "[]" ]]; then
  echo "No diagnostic settings found on this Application Gateway. Logs are not being sent to Log Analytics."
  echo "Cannot auto-discover any workspace. Exiting."
  exit 1
fi

echo "Diagnostic Settings:"
echo "$DIAG_SETTINGS_JSON" | jq .

# Extract the first workspaceId found (if multiple, pick the first)
# Adjust logic if you specifically want the setting that includes "ApplicationGatewayAccessLog".
WORKSPACE_RESOURCE_ID=$(
  echo "$DIAG_SETTINGS_JSON" | jq -r '
    .[]
    | select(.workspaceId != null)
    | .workspaceId
  ' \
  | head -n 1
)

if [[ -z "$WORKSPACE_RESOURCE_ID" || "$WORKSPACE_RESOURCE_ID" == "null" ]]; then
  echo "No Log Analytics workspaceId found in the diagnostic settings. Exiting."
  exit 1
fi

echo "Found Log Analytics workspace resource ID: $WORKSPACE_RESOURCE_ID"

# ------------------------------------------------------------------
# 2) Convert Log Analytics workspace resource ID -> workspace GUID (customerId)
# ------------------------------------------------------------------
WORKSPACE_GUID=$(
  az monitor log-analytics workspace show \
    --ids "$WORKSPACE_RESOURCE_ID" \
    --query "customerId" -o tsv 2>/dev/null || true
)

if [[ -z "$WORKSPACE_GUID" ]]; then
  echo "ERROR: Could not retrieve Log Analytics workspace GUID from $WORKSPACE_RESOURCE_ID"
  exit 1
fi

echo "Using Log Analytics workspace GUID: $WORKSPACE_GUID"

# ------------------------------------------------------------------
# Test query to verify workspace accessibility and response structure
# ------------------------------------------------------------------
echo "Testing Log Analytics workspace connectivity..."
TEST_QUERY="AzureDiagnostics | where TimeGenerated >= ago(1h) | take 1"
test_result=$(run_query "$TEST_QUERY" "json")
echo "DEBUG: Test query response structure:"
echo "$test_result" | jq '.' 2>/dev/null || echo "Invalid JSON response from test query"

# Check available fields in ApplicationGatewayAccessLog
echo "Checking available fields in ApplicationGatewayAccessLog..."
FIELDS_QUERY="AzureDiagnostics | where Category == 'ApplicationGatewayAccessLog' | where TimeGenerated >= ago(1h) | getschema"
fields_result=$(run_query "$FIELDS_QUERY" "json")
echo "DEBUG: Available fields in ApplicationGatewayAccessLog:"
echo "$fields_result" | jq '.' 2>/dev/null || echo "Could not retrieve field schema"

# Check what ResourceIds are present in ApplicationGatewayAccessLog
echo "Checking ResourceIds in ApplicationGatewayAccessLog..."
RESOURCE_IDS_QUERY="AzureDiagnostics | where Category == 'ApplicationGatewayAccessLog' | where TimeGenerated >= ago(1h) | distinct ResourceId"
resource_ids_result=$(run_query "$RESOURCE_IDS_QUERY" "json")
echo "DEBUG: ResourceIds in ApplicationGatewayAccessLog:"
echo "$resource_ids_result" | jq '.' 2>/dev/null || echo "Could not retrieve ResourceIds"

echo "DEBUG: Expected ResourceId: $AGW_RESOURCE_ID"

# ------------------------------------------------------------------
# Define Kusto queries, filtering by ResourceId == "$AGW_RESOURCE_ID"
# ------------------------------------------------------------------
REQ_COUNT_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "$AGW_RESOURCE_ID"
| where TimeGenerated >= ago(1h)
| summarize TotalRequests = count()
EOF
)

NON_SSL_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "$AGW_RESOURCE_ID"
| where TimeGenerated >= ago(1h)
| where isnotempty(sslEnabled_s) and sslEnabled_s == "off"
| summarize NonSSLRequests = count()
EOF
)

FAILED_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "$AGW_RESOURCE_ID"
| where TimeGenerated >= ago(1h)
| where isnotempty(httpStatus_d) and toint(httpStatus_d) >= 400
| summarize FailedRequests = count()
EOF
)

ERRORS_BY_UA_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "$AGW_RESOURCE_ID"
| where TimeGenerated >= ago(1h)
| where isnotempty(httpStatus_d) and toint(httpStatus_d) >= 400
| where isnotempty(userAgent_s)
| summarize ErrorCount = count() by userAgent_s
| order by ErrorCount desc
EOF
)

ERRORS_BY_URI_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "$AGW_RESOURCE_ID"
| where TimeGenerated >= ago(1h)
| where isnotempty(httpStatus_d) and toint(httpStatus_d) >= 400
| where isnotempty(requestUri_s)
| summarize ErrorCount = count() by requestUri_s
| order by ErrorCount desc
EOF
)

# Fallback queries without ResourceId filtering (in case ResourceId doesn't match)
REQ_COUNT_FALLBACK_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where TimeGenerated >= ago(1h)
| summarize TotalRequests = count()
EOF
)

NON_SSL_FALLBACK_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where TimeGenerated >= ago(1h)
| where isnotempty(sslEnabled_s) and sslEnabled_s == "off"
| summarize NonSSLRequests = count()
EOF
)

FAILED_FALLBACK_QUERY=$(cat <<EOF
AzureDiagnostics
| where Category == "ApplicationGatewayAccessLog"
| where TimeGenerated >= ago(1h)
| where isnotempty(httpStatus_d) and toint(httpStatus_d) >= 400
| summarize FailedRequests = count()
EOF
)

# Helper function to safely run a query and return "[]" or "0" if there's an error/no data
function run_query() {
  local query="$1"
  local output_format="${2:-tsv}"   # 'tsv' or 'json'
  local result
  local error_output

  # Capture both stdout and stderr
  if ! result=$(az monitor log-analytics query \
      --workspace "$WORKSPACE_GUID" \
      --analytics-query "$query" \
      -o "$output_format" 2>&1); then
    # If there's an error, log it and return empty
    echo "DEBUG: Query failed with error: $result" >&2
    if [ "$output_format" == "json" ]; then
      echo '{"tables":[]}'
    else
      echo "0"
    fi
    return
  fi

  # For JSON output, ensure we have a valid structure
  if [ "$output_format" == "json" ]; then
    # Check if result is empty or invalid JSON
    if [ -z "$result" ] || ! echo "$result" | jq '.' >/dev/null 2>&1; then
      echo "DEBUG: Invalid or empty JSON result: $result" >&2
      echo '{"tables":[]}'
      return
    fi
    
    # If result doesn't have tables structure, wrap it
    if ! echo "$result" | jq -e '.tables' >/dev/null 2>&1; then
      # Try to create a proper structure
      if echo "$result" | jq -e '.rows' >/dev/null 2>&1; then
        # If it has rows directly, wrap it in tables structure
        echo "$result" | jq '{"tables": [{"rows": .rows}]}'
      else
        echo "DEBUG: Unexpected JSON structure: $result" >&2
        echo '{"tables":[]}'
      fi
      return
    fi
  fi

  echo "$result"
}

# ------------------------------------------------------------------
# Run the queries
# ------------------------------------------------------------------
echo "Querying total requests in last hour..."
requests_last_hour=$(run_query "$REQ_COUNT_QUERY" "tsv")
requests_last_hour="${requests_last_hour:-0}"

# If no results with ResourceId filter, try without it
if [ "$requests_last_hour" == "0" ]; then
  echo "No results with ResourceId filter, trying fallback query..."
  requests_last_hour=$(run_query "$REQ_COUNT_FALLBACK_QUERY" "tsv")
  requests_last_hour="${requests_last_hour:-0}"
fi

echo "Querying non-SSL requests in last hour..."
non_ssl_requests_last_hour=$(run_query "$NON_SSL_QUERY" "tsv")
non_ssl_requests_last_hour="${non_ssl_requests_last_hour:-0}"

# If no results with ResourceId filter, try without it
if [ "$non_ssl_requests_last_hour" == "0" ]; then
  echo "No non-SSL results with ResourceId filter, trying fallback query..."
  non_ssl_requests_last_hour=$(run_query "$NON_SSL_FALLBACK_QUERY" "tsv")
  non_ssl_requests_last_hour="${non_ssl_requests_last_hour:-0}"
fi

echo "Querying failed requests in last hour..."
failed_requests_last_hour=$(run_query "$FAILED_QUERY" "tsv")
failed_requests_last_hour="${failed_requests_last_hour:-0}"

# If no results with ResourceId filter, try without it
if [ "$failed_requests_last_hour" == "0" ]; then
  echo "No failed request results with ResourceId filter, trying fallback query..."
  failed_requests_last_hour=$(run_query "$FAILED_FALLBACK_QUERY" "tsv")
  failed_requests_last_hour="${failed_requests_last_hour:-0}"
fi

echo "Querying errors by user agent..."
errors_by_user_agent_raw=$(run_query "$ERRORS_BY_UA_QUERY" "json")

# Debug: Show the raw response structure
echo "DEBUG: Raw errors_by_user_agent response structure:"
echo "$errors_by_user_agent_raw" | jq '.' 2>/dev/null || echo "Invalid JSON response"

errors_by_user_agent=$(
  echo "$errors_by_user_agent_raw" | jq -r '
    if .tables and (.tables | length) > 0 and .tables[0].rows then
      .tables[0].rows
      | map({ userAgent: .[0], count: (.[1] | tonumber) })
    else
      []
    end
  '
)

echo "Querying errors by request URI..."
errors_by_uri_raw=$(run_query "$ERRORS_BY_URI_QUERY" "json")

# Debug: Show the raw response structure
echo "DEBUG: Raw errors_by_uri response structure:"
echo "$errors_by_uri_raw" | jq '.' 2>/dev/null || echo "Invalid JSON response"

errors_by_uri=$(
  echo "$errors_by_uri_raw" | jq -r '
    if .tables and (.tables | length) > 0 and .tables[0].rows then
      .tables[0].rows
      | map({ uri: .[0], count: (.[1] | tonumber) })
    else
      []
    end
  '
)

# ------------------------------------------------------------------
# Build Final JSON
# ------------------------------------------------------------------
echo "Building final JSON output..."

# Ensure we have valid JSON arrays for the error collections
if [ -z "$errors_by_user_agent" ] || ! echo "$errors_by_user_agent" | jq '.' >/dev/null 2>&1; then
  errors_by_user_agent="[]"
fi

if [ -z "$errors_by_uri" ] || ! echo "$errors_by_uri" | jq '.' >/dev/null 2>&1; then
  errors_by_uri="[]"
fi

final_json=$(
  jq -n \
    --argjson requestsLastHour       "${requests_last_hour:-0}" \
    --argjson nonSslRequestsLastHour "${non_ssl_requests_last_hour:-0}" \
    --argjson failedRequestsLastHour "${failed_requests_last_hour:-0}" \
    --argjson errorsByUserAgent      "$errors_by_user_agent" \
    --argjson errorsByUri            "$errors_by_uri" \
    '
    {
      "requestsLastHour":        $requestsLastHour,
      "nonSslRequestsLastHour":  $nonSslRequestsLastHour,
      "failedRequestsLastHour":  $failedRequestsLastHour,
      "errorsByUserAgent":       $errorsByUserAgent,
      "errorsByUri":             $errorsByUri
    }
    ' 2>/dev/null || echo '{
      "requestsLastHour": 0,
      "nonSslRequestsLastHour": 0,
      "failedRequestsLastHour": 0,
      "errorsByUserAgent": [],
      "errorsByUri": []
    }'
)

# Print and save
echo "-------------------------------------------------"
echo "Application Gateway Log-Based Metrics (Last Hour)"
if echo "$final_json" | jq '.' >/dev/null 2>&1; then
  echo "$final_json" | jq .
else
  echo "ERROR: Invalid JSON output generated. Using fallback structure."
  echo '{
    "requestsLastHour": 0,
    "nonSslRequestsLastHour": 0,
    "failedRequestsLastHour": 0,
    "errorsByUserAgent": [],
    "errorsByUri": []
  }' | jq .
  final_json='{
    "requestsLastHour": 0,
    "nonSslRequestsLastHour": 0,
    "failedRequestsLastHour": 0,
    "errorsByUserAgent": [],
    "errorsByUri": []
  }'
fi
echo "-------------------------------------------------"
echo "$final_json" > "$OUTPUT_FILE"
echo "Metrics have been saved to: $OUTPUT_FILE."
