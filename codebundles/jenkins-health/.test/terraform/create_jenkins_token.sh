#!/usr/bin/bash
# echo '{"token": "hello"}'
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

set -x

# 1) Read JSON input from stdin
read -r input

# All debug statements go to stderr via >&2
echo "[DEBUG] Received JSON input: $input" >&2

JENKINS_URL=$(echo "$input" | jq -r .jenkins_url)
USERNAME=$(echo "$input" | jq -r .username)
PASSWORD=$(echo "$input" | jq -r .password)

echo "[DEBUG] Jenkins URL: $JENKINS_URL" >&2
echo "[DEBUG] Username:    $USERNAME" >&2

# 2) Wait for Jenkins up to MAX_ATTEMPTS
MAX_ATTEMPTS=100
SLEEP_SECONDS=10
echo "[DEBUG] Checking Jenkins readiness up to $MAX_ATTEMPTS attempts..." >&2

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  STATUS_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 5 \
    -u "${USERNAME}:${PASSWORD}" \
    "${JENKINS_URL}/api/json" || echo "curl_error")

  if [ "$STATUS_CODE" = "200" ]; then
    echo "[DEBUG] Jenkins responded HTTP 200 on attempt #$i." >&2
    break
  else
    echo "[DEBUG] Attempt #$i: HTTP $STATUS_CODE. Retrying in $SLEEP_SECONDS seconds..." >&2
    sleep "$SLEEP_SECONDS"
  fi

  if [ "$i" -eq "$MAX_ATTEMPTS" ]; then
    echo "[ERROR] Jenkins not ready after $MAX_ATTEMPTS attempts." >&2
    # Return some valid JSON to Terraform (it sees failure).
    echo '{"error":"Jenkins never returned 200"}'
    exit 1
  fi
done

# 3) Generate a new token
echo "[DEBUG] Generating a new token via REST..." >&2

RESPONSE=$(curl -s -X POST \
  --max-time 10 \
  -u "${USERNAME}:${PASSWORD}" \
  --data "newTokenName=terraformToken" \
  "${JENKINS_URL}/user/${USERNAME}/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" || true)

echo "[DEBUG] Response: $RESPONSE" >&2

TOKEN_VALUE=$(echo "$RESPONSE" | jq -r '.data.tokenValue' 2>/dev/null || echo "")

if [ -z "$TOKEN_VALUE" ] || [ "$TOKEN_VALUE" = "null" ]; then
  echo "[ERROR] Could not parse a valid token from the response." >&2
  echo "[ERROR] Full response: $RESPONSE" >&2
  echo '{"error":"Token generation failed"}'
  exit 1
fi

echo "[DEBUG] Successfully generated token: $TOKEN_VALUE" >&2

# 4) Print only JSON to stdout
cat <<EOF
{
  "token": "$TOKEN_VALUE"
}
EOF
