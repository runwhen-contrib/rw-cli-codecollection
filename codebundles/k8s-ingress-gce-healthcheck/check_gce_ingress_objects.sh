#!/bin/bash
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

set -eo pipefail


# Check if a command exists
function check_command_exists() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 could not be found"
        exit
    fi
}

# ------------------------- Dependency Verification ---------------------------

# Ensure all the required binaries are accessible
check_command_exists ${KUBERNETES_DISTRIBUTION_BINARY}
check_command_exists gcloud

# Auth to gcloud
gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS

# Extract the necessary annotations from the Ingress
FORWARDING_RULE=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/forwarding-rule}')
URL_MAP=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/url-map}')
TARGET_PROXY=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/target-proxy}')
BACKENDS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}')
BACKENDS=( $(echo $BACKENDS_JSON | jq -r 'keys[]') )  # Assuming jq is installed for JSON parsing

recommendations=()

# Verify Forwarding Rule
echo "--- Verifying Forwarding Rule $FORWARDING_RULE ---"
if ! gcloud compute forwarding-rules describe $FORWARDING_RULE --global --project=$GCP_PROJECT_ID &>/dev/null; then
    recommendations+=("Warning: Forwarding Rule [$FORWARDING_RULE] doesn't exist! Verify the correctness of the Ingress configuration and ensure the forwarding rule is properly created.")
fi

# Verify URL Map
echo "--- Verifying URL Map $URL_MAP ---"
if ! gcloud compute url-maps describe $URL_MAP --global --project=$GCP_PROJECT_ID &>/dev/null; then
    recommendations+=("Warning: URL Map [$URL_MAP] doesn't exist! Check the associated ingress controller's logs and the GCP logs for any errors relating to the URL map creation.")
fi

# Verify Target Proxy (both HTTP and HTTPS)
echo "--- Verifying Target Proxy $TARGET_PROXY ---"
if ! gcloud compute target-https-proxies describe $TARGET_PROXY --global --project=$GCP_PROJECT_ID &>/dev/null && ! gcloud compute target-http-proxies describe $TARGET_PROXY --global --project=$GCP_PROJECT_ID &>/dev/null; then
    recommendations+=("Warning: Target Proxy [$TARGET_PROXY] doesn't exist! Ensure the Ingress is correctly set up to create the required target proxy.")
fi

# Display Backend Service's health status and check for problematic backends
echo "--- Backend Service Health Status ---"
for backend in "${BACKENDS[@]}"; do
    health_status=$(gcloud compute backend-services get-health $backend --global --project=$GCP_PROJECT_ID)
    echo "Backend Service: $backend"
    echo "$health_status"
    echo "-----------------------------"
    
    if [[ ! $health_status =~ "HEALTHY" ]] || [[ $health_status =~ "UNHEALTHY" ]]; then
        recommendations+=("Warning: Backend Service [$backend] has problematic health status. Check health checks and firewall rules for this backend. View GCP Logs. Verify IPs are on routable subnets (container-native load balancing) or using NodePort.")
    fi
done

# Display aggregated recommendations
if [[ ${#recommendations[@]} -ne 0 ]]; then
    echo "Recommendations:"
    for recommendation in "${recommendations[@]}"; do
        echo "- $recommendation"
    done
    
else
    echo "All resources associated with the ingress appear healthy."
fi