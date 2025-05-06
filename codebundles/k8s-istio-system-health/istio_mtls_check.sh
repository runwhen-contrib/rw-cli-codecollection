#!/bin/bash

echo "🔍 Checking Istio mTLS Certificates for all Istio-injected pods in context: ${CONTEXT}"
echo "Using Kubernetes CLI: ${KUBERNETES_DISTRIBUTION_BINARY}"

# Output files
REPORT_FILE="istio_mtls_cert_report.txt"
ISSUES_FILE="istio_mtls_issues.json"

# Temporary files
ROOT_CA_FILE="/tmp/root_ca_tmp"
MTLS_FILE="/tmp/mtls_tmp"

# Clean old data
> "$ROOT_CA_FILE"
> "$MTLS_FILE"
echo "" > "$REPORT_FILE"
echo "[]" > "$ISSUES_FILE"
ISSUES=()

# Check dependencies
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 not found"
        exit 1
    fi
}

check_command_exists jq
check_command_exists istioctl
check_command_exists "$KUBERNETES_DISTRIBUTION_BINARY"

# Check cluster connection
function check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" >/dev/null 2>&1; then
        echo "Error: Unable to connect to cluster context '${CONTEXT}'"
        exit 1
    fi
}

check_cluster_connection

# Get all namespaces
${KUBERNETES_DISTRIBUTION_BINARY} get ns --no-headers -o custom-columns=":metadata.name" --context="${CONTEXT}" | while read -r NS; do
    # Get all Istio-injected pods
    ${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NS" -o json --context="${CONTEXT}" | jq -r '.items[] | select(.spec.containers[].name == "istio-proxy") | "\(.metadata.name)"' | while read -r POD; do

        # Check if pod is running
        POD_PHASE=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" -o jsonpath="{.status.phase}" --context="${CONTEXT}")
        if [[ "$POD_PHASE" != "Running" ]]; then
            ISSUE=$(jq -n \
                --arg severity "1" \
                --arg expected "Pod $POD should be in Running state for certificate check in namepsace $NS" \
                --arg actual "Pod $POD is in $POD_PHASE phase in namespace $NS" \
                --arg title "Skipping mTLS certificate check for pod $POD in namespace $NS" \
                --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context=$CONTEXT" \
                --arg next_steps "Ensure pod is healthy and running before verifying mTLS certs" \
                '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')
            ISSUES+=("$ISSUE")
            continue
        fi

        # Get Istio secret details
        CERT_OUTPUT=$(istioctl proxy-config secret "$POD" -n "$NS" --context="${CONTEXT}")
        echo "$CERT_OUTPUT" > "/tmp/${POD}_${NS}_cert_debug.txt"  # Optional debug

        # Parse ROOTCA line
        echo "$CERT_OUTPUT" | grep -A1 "ROOTCA" | tail -n1 | awk '{print $5, $3, $4, $6, $7}' >> "$ROOT_CA_FILE"

        # Parse Cert Chain line
        echo "$CERT_OUTPUT" | grep -A1 "Cert Chain" | tail -n1 | awk -v pod="$POD" -v ns="$NS" '{print pod, ns, $6, $4, $5, $7, $8}' >> "$MTLS_FILE"
    done
done

# Generate Root CA Table
echo "" >> "$REPORT_FILE"
echo "📜 Root CA Certificate" >> "$REPORT_FILE"
echo "----------------------------------------------------------------------------------------------------------------------" >> "$REPORT_FILE"
printf "%-45s %-10s %-12s %-25s %-25s\n" "Serial Number" "Status" "Valid Cert" "Not After" "Not Before" >> "$REPORT_FILE"
echo "----------------------------------------------------------------------------------------------------------------------" >> "$REPORT_FILE"
sort -u "$ROOT_CA_FILE" | while read -r serial status valid not_after not_before; do
    printf "%-45s %-10s %-12s %-25s %-25s\n" "$serial" "$status" "$valid" "$not_after" "$not_before" >> "$REPORT_FILE"

    if [[ "$valid" != "true" ]]; then
        ISSUE=$(jq -n \
            --arg severity "2" \
            --arg expected "Root CA certificate should be valid for cluster ${CLUSTER}" \
            --arg actual "Root CA $serial is not valid (valid=$valid) for cluster ${CLUSTER}" \
            --arg title "Invalid Root CA certificate found for cluster ${CLUSTER}" \
            --arg reproduce_hint "Check with: istioctl proxy-config secret <pod> -n <namespace> --context=$CONTEXT" \
            --arg next_steps "Investigate certificate provisioning and ensure the CA is valid and trusted" \
            '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')
        ISSUES+=("$ISSUE")
    fi
done
echo "" >> "$REPORT_FILE"

# Generate mTLS Certificates Table
echo "📜 mTLS Certificates" >> "$REPORT_FILE"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------" >> "$REPORT_FILE"
printf "%-40s %-20s %-45s %-10s %-12s %-25s %-25s\n" "Pod Name" "Namespace" "Serial Number" "Status" "Valid Cert" "Not After" "Not Before" >> "$REPORT_FILE"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------" >> "$REPORT_FILE"
cat "$MTLS_FILE" | while read -r pod ns serial status valid not_after not_before; do
    printf "%-40s %-20s %-45s %-10s %-12s %-25s %-25s\n" "$pod" "$ns" "$serial" "$status" "$valid" "$not_after" "$not_before" >> "$REPORT_FILE"

    if [[ "$valid" != "true" ]]; then
        ISSUE=$(jq -n \
            --arg severity "2" \
            --arg expected "mTLS certificate should be valid for pod $pod in namespace $ns" \
            --arg actual "mTLS certificate for pod $pod (serial=$serial) is not valid in namespace $ns" \
            --arg title "Invalid mTLS certificate for pod $pod in namespace $ns" \
            --arg reproduce_hint "istioctl proxy-config secret $pod -n $ns --context=$CONTEXT" \
            --arg next_steps "Restart the pod or investigate certificate provisioning issues" \
            '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')
        ISSUES+=("$ISSUE")
    fi
done

# Save issues if any
echo "${ISSUES[*]}"
if [ "${#ISSUES[@]}" -gt 0 ]; then
    printf "[\n%s\n]\n" "$(IFS=,; echo "${ISSUES[*]}")" > "$ISSUES_FILE"
else
    echo "" >> "$REPORT_FILE"
    echo "✅ All mTLS and Root CA certificates are valid." >> "$REPORT_FILE"
fi

# Cleanup
#rm -f "$ROOT_CA_FILE" "$MTLS_FILE"
