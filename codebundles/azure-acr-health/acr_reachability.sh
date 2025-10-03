#!/bin/bash

# Azure Container Registry Reachability Check
# Tests DNS resolution and TLS connectivity to ACR endpoint

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

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}

ISSUES_FILE="reachability_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
    local title="$1"
    local severity="$2"
    local expected="$3"
    local actual="$4"
    local details="$5"
    local next_steps="$6"
    
    # Escape quotes and newlines for JSON
    details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\"}"
    jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

# Check required environment variables
missing_vars=()
if [ -z "$ACR_NAME" ]; then
    missing_vars+=("ACR_NAME")
fi

if [ ${#missing_vars[@]} -ne 0 ]; then
    add_issue \
        "Missing Environment Variables" \
        2 \
        "All required environment variables should be set" \
        "Missing variables: ${missing_vars[*]}" \
        "Required variables: ACR_NAME" \
        "Set the missing environment variables and retry"
    
    echo "❌ Missing required environment variables: ${missing_vars[*]}" >&2
    
    # Still output JSON even when there are missing variables
    cat "$ISSUES_FILE"
    exit 0
fi

echo "🔍 Testing ACR reachability for registry: $ACR_NAME" >&2

# Construct ACR login server URL
LOGIN_SERVER="${ACR_NAME}.azurecr.io"
echo "🌐 Testing connectivity to: $LOGIN_SERVER" >&2

# Test DNS resolution
echo "🔍 Testing DNS resolution..." >&2
dns_result=$(nslookup "$LOGIN_SERVER" 2>&1)
dns_exit_code=$?

if [ $dns_exit_code -eq 0 ]; then
    echo "✅ DNS resolution successful" >&2
    ip_addresses=$(echo "$dns_result" | grep -A 10 "Non-authoritative answer:" | grep "Address:" | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
    echo "   Resolved IPs: $ip_addresses" >&2
else
    echo "❌ DNS resolution failed" >&2
    add_issue \
        "DNS Resolution Failed" \
        1 \
        "DNS should resolve $LOGIN_SERVER to IP addresses" \
        "DNS lookup failed with exit code $dns_exit_code" \
        "DNS lookup error: $dns_result" \
        "Check network connectivity and DNS settings. Verify ACR name \`$ACR_NAME\` is correct and registry exists in resource group \`$RESOURCE_GROUP\`"
fi

# Test HTTPS connectivity
echo "🔐 Testing HTTPS connectivity..." >&2
https_result=$(curl -I -s -w "HTTP_CODE:%{http_code};TOTAL_TIME:%{time_total};CONNECT_TIME:%{time_connect}" \
    --max-time 30 \
    --connect-timeout 10 \
    "https://$LOGIN_SERVER/v2/" 2>&1)
curl_exit_code=$?

if [ $curl_exit_code -eq 0 ]; then
    http_code=$(echo "$https_result" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    total_time=$(echo "$https_result" | grep -o "TOTAL_TIME:[0-9.]*" | cut -d: -f2)
    connect_time=$(echo "$https_result" | grep -o "CONNECT_TIME:[0-9.]*" | cut -d: -f2)
    
    echo "✅ HTTPS connectivity successful" >&2
    echo "   HTTP Status: $http_code" >&2
    echo "   Total Time: ${total_time}s" >&2
    echo "   Connect Time: ${connect_time}s" >&2
    
    # Check if response time is reasonable (> 5 seconds might indicate issues)
    if (( $(echo "$total_time > 5.0" | bc -l) )); then
        add_issue \
            "Slow HTTPS Response" \
            3 \
            "HTTPS response should be under 5 seconds" \
            "Response time: ${total_time}s" \
            "Connection is slow, which may indicate network issues or ACR performance problems" \
            "Check network latency and ACR \`$ACR_NAME\` performance. Consider using a closer Azure region for resource group \`$RESOURCE_GROUP\`"
    fi
    
    # Check HTTP status code
    if [ "$http_code" != "401" ] && [ "$http_code" != "200" ]; then
        add_issue \
            "Unexpected HTTP Status Code" \
            2 \
            "HTTP status should be 200 or 401 (auth required)" \
            "Received HTTP status: $http_code" \
            "ACR endpoint returned unexpected status code" \
            "Investigate ACR \`$ACR_NAME\` service health and authentication requirements in resource group \`$RESOURCE_GROUP\`"
    fi
else
    echo "❌ HTTPS connectivity failed" >&2
    add_issue \
        "HTTPS Connectivity Failed" \
        1 \
        "HTTPS connection should succeed to $LOGIN_SERVER" \
        "HTTPS connection failed with exit code $curl_exit_code" \
        "Connection error: $https_result" \
        "Check network connectivity, firewall rules (port 443), and proxy settings. Verify ACR \`$ACR_NAME\` service status in resource group \`$RESOURCE_GROUP\`"
fi

# Test TLS certificate validity
echo "🔒 Testing TLS certificate..." >&2
cert_result=$(echo | openssl s_client -connect "$LOGIN_SERVER:443" -servername "$LOGIN_SERVER" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
openssl_exit_code=$?

if [ $openssl_exit_code -eq 0 ]; then
    echo "✅ TLS certificate validation successful" >&2
    not_before=$(echo "$cert_result" | grep "notBefore" | cut -d= -f2)
    not_after=$(echo "$cert_result" | grep "notAfter" | cut -d= -f2)
    echo "   Valid from: $not_before" >&2
    echo "   Valid until: $not_after" >&2
    
    # Check certificate expiry (warn if expiring within 30 days)
    expiry_timestamp=$(date -d "$not_after" +%s 2>/dev/null || echo "0")
    current_timestamp=$(date +%s)
    days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
    
    if [ "$expiry_timestamp" != "0" ] && [ $days_until_expiry -lt 30 ]; then
        add_issue \
            "TLS Certificate Expiring Soon" \
            3 \
            "TLS certificate should be valid for more than 30 days" \
            "Certificate expires in $days_until_expiry days" \
            "Certificate expires on: $not_after" \
            "Monitor certificate renewal for ACR \`$ACR_NAME\`. Azure typically handles ACR certificate renewal automatically for registries in resource group \`$RESOURCE_GROUP\`"
    fi
else
    echo "❌ TLS certificate validation failed" >&2
    add_issue \
        "TLS Certificate Validation Failed" \
        2 \
        "TLS certificate should be valid and trusted" \
        "Certificate validation failed" \
        "Unable to validate TLS certificate for $LOGIN_SERVER" \
        "Check if ACR \`$ACR_NAME\` is accessible and certificate is properly configured in resource group \`$RESOURCE_GROUP\`"
fi

# Test Docker Registry v2 API endpoint
echo "🐳 Testing Docker Registry API..." >&2
api_result=$(curl -s -w "HTTP_CODE:%{http_code}" --max-time 15 "https://$LOGIN_SERVER/v2/" 2>/dev/null)
api_exit_code=$?

if [ $api_exit_code -eq 0 ]; then
    api_http_code=$(echo "$api_result" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    echo "✅ Docker Registry API accessible" >&2
    echo "   API Status: $api_http_code" >&2
    
    if [ "$api_http_code" = "401" ]; then
        echo "   (401 is expected - authentication required)" >&2
    elif [ "$api_http_code" != "200" ]; then
        add_issue \
            "Docker Registry API Unexpected Response" \
            3 \
            "Docker Registry API should return 200 or 401" \
            "API returned HTTP $api_http_code" \
            "Docker Registry v2 API endpoint returned unexpected status" \
            "Check ACR \`$ACR_NAME\` service status and API availability in resource group \`$RESOURCE_GROUP\`"
    fi
else
    echo "❌ Docker Registry API test failed" >&2
    add_issue \
        "Docker Registry API Unreachable" \
        2 \
        "Docker Registry API should be accessible" \
        "API test failed with exit code $api_exit_code" \
        "Unable to reach Docker Registry v2 API endpoint" \
        "Check ACR \`$ACR_NAME\` service health and network connectivity to the registry API in resource group \`$RESOURCE_GROUP\`"
fi

# Output summary to stderr so it doesn't interfere with JSON parsing
echo "" >&2
echo "🎯 Reachability Summary:" >&2
echo "   Registry: $LOGIN_SERVER" >&2
echo "   DNS: $([ $dns_exit_code -eq 0 ] && echo "✅ Resolved" || echo "❌ Failed")" >&2
echo "   HTTPS: $([ $curl_exit_code -eq 0 ] && echo "✅ Connected" || echo "❌ Failed")" >&2
echo "   TLS: $([ $openssl_exit_code -eq 0 ] && echo "✅ Valid" || echo "❌ Invalid")" >&2
echo "   API: $([ $api_exit_code -eq 0 ] && echo "✅ Accessible" || echo "❌ Failed")" >&2

echo "" >&2
echo "ACR reachability check completed." >&2

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"