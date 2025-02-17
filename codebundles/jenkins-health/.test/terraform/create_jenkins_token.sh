#!/usr/bin/env bash
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
MAX_ATTEMPTS=10
SLEEP_SECONDS=5
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
