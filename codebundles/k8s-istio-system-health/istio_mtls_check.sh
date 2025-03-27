#!/bin/bash

echo "🔍 Checking Istio mTLS Certificates for all Istio-injected pods in context: ${CONTEXT}"
echo "Using Kubernetes CLI: ${KUBERNETES_DISTRIBUTION_BINARY}"

# Temporary files
ROOT_CA_FILE="/tmp/root_ca_tmp"
MTLS_FILE="/tmp/mtls_tmp"

# Clean old data
> "$ROOT_CA_FILE"
> "$MTLS_FILE"

# Get all namespaces
${KUBERNETES_DISTRIBUTION_BINARY} get ns --no-headers -o custom-columns=":metadata.name" --context="${CONTEXT}" | while read -r NS; do
    # Get all Istio-injected pods
    ${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NS" -o json --context="${CONTEXT}" | jq -r '
        .items[] | select(.spec.containers[].name == "istio-proxy") | "\(.metadata.name)"' | while read -r POD; do
        
        # Get Istio secret details
        istioctl proxy-config secret "$POD" -n "$NS" --context="${CONTEXT}" | awk -v pod="$POD" -v ns="$NS" '
            /ROOTCA/ {
                print $5, $3, $4, $6, $7 >> "'"$ROOT_CA_FILE"'"
            }
            /Cert Chain/ {
                print pod, ns, $6, $4, $5, $7, $8 >> "'"$MTLS_FILE"'"
            }'
    done
done

# Print Root CA Table (Ensuring Unique Entries)
echo ""
echo "📜 Root CA Certificate"
echo "----------------------------------------------------------------------------------------------------------------------"
printf "%-45s %-10s %-12s %-25s %-25s\n" "Serial Number" "Status" "Valid Cert" "Not After" "Not Before"
echo "----------------------------------------------------------------------------------------------------------------------"
sort -u "$ROOT_CA_FILE" | while read -r serial status valid not_after not_before; do
    printf "%-45s %-10s %-12s %-25s %-25s\n" "$serial" "$status" "$valid" "$not_after" "$not_before"
done
echo ""

# Print mTLS Certificates Table
echo "📜 mTLS Certificates"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------"
printf "%-40s %-20s %-45s %-10s %-12s %-25s %-25s\n" "Pod Name" "Namespace" "Serial Number" "Status" "Valid Cert" "Not After" "Not Before"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------"
cat "$MTLS_FILE" | while read -r pod ns serial status valid not_after not_before; do
    printf "%-40s %-20s %-45s %-10s %-12s %-25s %-25s\n" "$pod" "$ns" "$serial" "$status" "$valid" "$not_after" "$not_before"
done

# Cleanup
rm -f "$ROOT_CA_FILE" "$MTLS_FILE"
