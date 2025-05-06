#!/bin/bash

echo "🔍 Checking Istio mTLS Certificates for all Istio-injected pods in context: ${CONTEXT}"
echo "Using Kubernetes CLI: ${KUBERNETES_DISTRIBUTION_BINARY}"

# ---------------------------------------------------------------------------
# Output & temp files
REPORT_FILE="istio_mtls_cert_report.txt"
ISSUES_FILE="istio_mtls_issues.json"
ROOT_CA_FILE="/tmp/root_ca_tmp"
MTLS_FILE="/tmp/mtls_tmp"

> "$ROOT_CA_FILE"; > "$MTLS_FILE"
echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"
declare -a ISSUES=()

# ---------------------------------------------------------------------------
# helpers
check_command_exists() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: $1 not found"
        exit 1
    fi
}

check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &>/dev/null; then
        echo "Error: Unable to connect to cluster context '${CONTEXT}'"
        exit 1
    fi
}

check_command_exists jq
check_command_exists istioctl
check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_cluster_connection

# ---------------------------------------------------------------------------
# gather certificates
"${KUBERNETES_DISTRIBUTION_BINARY}" get ns --no-headers -o custom-columns=":metadata.name" \
    --context="${CONTEXT}" | while read -r NS; do

    "${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$NS" -o json --context="${CONTEXT}" \
        | jq -r '.items[] | select(.spec.containers[].name=="istio-proxy") | .metadata.name' \
        | while read -r POD; do

            POD_PHASE=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                        -o jsonpath="{.status.phase}" --context="${CONTEXT}")

            if [[ "$POD_PHASE" != "Running" ]]; then
                # ------------- issue: pod not running -------------
                ISSUES+=("$(jq -n \
                    --arg severity "1" \
                    --arg expected "Pod $POD should be Running to verify certificates" \
                    --arg actual "Pod $POD is $POD_PHASE" \
                    --arg title "Skipping mTLS certificate check for pod \`$POD\` in namespace \`$NS\`" \
                    --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context=$CONTEXT" \
                    --arg next_steps "Ensure the pod is healthy before verifying mTLS certificates" \
                    --arg pod "$POD" --arg ns "$NS" --arg phase "$POD_PHASE" \
                    '{severity:$severity,expected:$expected,actual:$actual,title:$title,
                      reproduce_hint:$reproduce,next_steps:$next_steps,
                      details:{pod:$pod,namespace:$ns,phase:$phase}}')"
                )
                continue
            fi

            CERT_OUTPUT=$(istioctl proxy-config secret "$POD" -n "$NS" --context="${CONTEXT}")
            echo "$CERT_OUTPUT" > "/tmp/${POD}_${NS}_cert_debug.txt"  # debug

            # ROOTCA
            echo "$CERT_OUTPUT" | grep -A1 "ROOTCA" | tail -n1 \
                | awk '{print $5, $3, $4, $6, $7}' >>"$ROOT_CA_FILE"

            # Cert Chain
            echo "$CERT_OUTPUT" | grep -A1 "Cert Chain" | tail -n1 \
                | awk -v pod="$POD" -v ns="$NS" \
                      '{print pod, ns, $6, $4, $5, $7, $8}' >>"$MTLS_FILE"
    done
done

# ---------------------------------------------------------------------------
# Root-CA table & issues
{
    echo ""
    echo "📜 Root CA Certificate"
    echo "----------------------------------------------------------------------------------------------------------------------"
    printf "%-45s %-10s %-12s %-25s %-25s\n" "Serial Number" "Status" "Valid Cert" "Not After" "Not Before"
    echo "----------------------------------------------------------------------------------------------------------------------"
} >>"$REPORT_FILE"

sort -u "$ROOT_CA_FILE" | while read -r serial status valid not_after not_before; do
    printf "%-45s %-10s %-12s %-25s %-25s\n" \
        "$serial" "$status" "$valid" "$not_after" "$not_before" >>"$REPORT_FILE"

    if [[ "$valid" != "true" ]]; then
        # ------------- issue: invalid Root-CA -------------
        ISSUES+=("$(jq -n \
            --arg severity "2" \
            --arg expected "Root CA certificate should be valid" \
            --arg actual "Root CA $serial is not valid (valid=$valid)" \
            --arg title "Invalid Root CA certificate found for cluster \`${CONTEXT}\`" \
            --arg reproduce "istioctl proxy-config secret <pod> -n <namespace> --context=$CONTEXT | grep -A1 ROOTCA" \
            --arg next_steps "Investigate certificate provisioning and trust chain" \
            --arg serial "$serial" --arg stat "$status" --arg val "$valid" \
            --arg na "$not_after" --arg nb "$not_before" \
            '{severity:$severity,expected:$expected,actual:$actual,title:$title,
              reproduce_hint:$reproduce,next_steps:$next_steps,
              details:{serial:$serial,status:$stat,valid:$val,not_after:$na,not_before:$nb}}')"
        )
    fi
done

# ---------------------------------------------------------------------------
# mTLS cert table & issues
{
    echo ""
    echo "📜 mTLS Certificates"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------"
    printf "%-40s %-20s %-45s %-10s %-12s %-25s %-25s\n" \
           "Pod Name" "Namespace" "Serial Number" "Status" "Valid Cert" "Not After" "Not Before"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------"
} >>"$REPORT_FILE"

cat "$MTLS_FILE" | while read -r pod ns serial status valid not_after not_before; do
    printf "%-40s %-20s %-45s %-10s %-12s %-25s %-25s\n" \
        "$pod" "$ns" "$serial" "$status" "$valid" "$not_after" "$not_before" >>"$REPORT_FILE"

    if [[ "$valid" != "true" ]]; then
        # ------------- issue: invalid mTLS cert -------------
        ISSUES+=("$(jq -n \
            --arg severity "2" \
            --arg expected "mTLS certificate should be valid for pod $pod in namespace $ns" \
            --arg actual "mTLS certificate for pod $pod (serial=$serial) is not valid" \
            --arg title "Invalid mTLS certificate for pod \`$pod\` in namespace \`$ns\`" \
            --arg reproduce "istioctl proxy-config secret $pod -n $ns --context=$CONTEXT | grep -A1 'Cert Chain'" \
            --arg next_steps "Restart the pod or investigate certificate provisioning issues" \
            --arg pod "$pod" --arg ns "$ns" \
            --arg serial "$serial" --arg stat "$status" --arg val "$valid" \
            --arg na "$not_after" --arg nb "$not_before" \
            '{severity:$severity,expected:$expected,actual:$actual,title:$title,
              reproduce_hint:$reproduce,next_steps:$next_steps,
              details:{pod:$pod,namespace:$ns,serial:$serial,status:$stat,valid:$val,
                       not_after:$na,not_before:$nb}}')"
        )
    fi
done

# ---------------------------------------------------------------------------
# save issues
if (( ${#ISSUES[@]} > 0 )); then
    printf '%s\n' "${ISSUES[@]}" | jq -s . >"$ISSUES_FILE"
else
    echo "" >>"$REPORT_FILE"
    echo "✅ All mTLS and Root-CA certificates are valid." >>"$REPORT_FILE"
fi

# Optionally clean up temp files
# rm -f "$ROOT_CA_FILE" "$MTLS_FILE"
