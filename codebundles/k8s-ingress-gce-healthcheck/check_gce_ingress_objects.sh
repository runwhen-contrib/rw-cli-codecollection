#!/bin/bash


# Extract the necessary annotations from the Ingress
FORWARDING_RULE=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/forwarding-rule}')
URL_MAP=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/url-map}')
TARGET_PROXY=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/target-proxy}')
BACKENDS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE -o=jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}')
BACKENDS=( $(echo $BACKENDS_JSON | jq -r 'keys[]') )  # Assuming jq is installed for JSON parsing

recommendations=()

# Verify Forwarding Rule
echo "=== Verifying Forwarding Rule $FORWARDING_RULE ==="
if ! gcloud compute forwarding-rules describe $FORWARDING_RULE --global --project=$GCP_PROJECT_ID &>/dev/null; then
    recommendations+=("Warning: Forwarding Rule [$FORWARDING_RULE] doesn't exist! Verify the correctness of the Ingress configuration and ensure the forwarding rule is properly created.")
fi

# Verify URL Map
echo "=== Verifying URL Map $URL_MAP ==="
if ! gcloud compute url-maps describe $URL_MAP --global --project=$GCP_PROJECT_ID &>/dev/null; then
    recommendations+=("Warning: URL Map [$URL_MAP] doesn't exist! Check the associated ingress controller's logs and the GCP logs for any errors relating to the URL map creation.")
fi

# Verify Target Proxy (both HTTP and HTTPS)
echo "=== Verifying Target Proxy $TARGET_PROXY ==="
if ! gcloud compute target-https-proxies describe $TARGET_PROXY --global --project=$GCP_PROJECT_ID &>/dev/null && ! gcloud compute target-http-proxies describe $TARGET_PROXY --global --project=$GCP_PROJECT_ID &>/dev/null; then
    recommendations+=("Warning: Target Proxy [$TARGET_PROXY] doesn't exist! Ensure the Ingress is correctly set up to create the required target proxy.")
fi

# Display Backend Service's health status and check for problematic backends
echo "=== Backend Service Health Status ==="
for backend in "${BACKENDS[@]}"; do
    health_status=$(gcloud compute backend-services get-health $backend --global --project=$GCP_PROJECT_ID)
    echo "Backend Service: $backend"
    echo "$health_status"
    echo "-----------------------------"
    
    if [[ ! $health_status =~ "HEALTHY" ]] || [[ $health_status =~ "UNHEALTHY" ]]; then
        recommendations+=("Warning: Backend Service [$backend] has problematic health status. Check health checks and firewall rules for this backend.")
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