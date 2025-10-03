#!/bin/bash
# Script to verify APIM policy configurations
# Focuses on troubleshooting issues that affect functionality

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

: "${APIM_NAME:?Environment variable APIM_NAME must be set}"
: "${AZ_RESOURCE_GROUP:?Environment variable AZ_RESOURCE_GROUP must be set}"

OUTPUT_FILE="apim_policy_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Verifying APIM Policy Configurations for \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\`..."

###############################################################################
# Helper function to validate XML and extract policy errors
###############################################################################
validate_policy_xml() {
    local xml_content="$1"
    local policy_context="$2"
    
    # Check if XML is well-formed
    if ! echo "$xml_content" | xmllint --noout - 2>/dev/null; then
        return 1
    fi
    
    # Check for common problematic patterns
    if echo "$xml_content" | grep -i "error\|exception\|failed" >/dev/null; then
        return 2
    fi
    
    return 0
}

###############################################################################
# Helper function to check for authentication failures in policies
###############################################################################
check_auth_issues() {
    local xml_content="$1"
    local context="$2"
    
    # Look for authentication policies that might cause issues
    if echo "$xml_content" | grep -i "authentication-basic" | grep -i "password.*null\|username.*null" >/dev/null; then
        issues_json=$(echo "$issues_json" | jq \
            --arg t "$context: Basic Authentication Credentials Missing" \
            --arg d "Basic authentication policy found with null/empty credentials" \
            --arg s "2" \
            --arg n "Verify basic authentication credentials are properly configured" \
            '.issues += [{
               "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
             }]')
    fi
    
    # Check for JWT validation without proper keys
    if echo "$xml_content" | grep -i "validate-jwt" | grep -v "key\|certificate\|openid-config" >/dev/null; then
        issues_json=$(echo "$issues_json" | jq \
            --arg t "$context: JWT Validation Without Signing Key" \
            --arg d "JWT validation policy found without proper signing key configuration" \
            --arg s "3" \
            --arg n "Configure signing keys or OpenID configuration for JWT validation" \
            '.issues += [{
               "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
             }]')
    fi
}

###############################################################################
# Helper function to check for backend connectivity issues
###############################################################################
check_backend_issues() {
    local xml_content="$1"
    local context="$2"
    
    # Check for set-backend-service with invalid URLs
    backend_urls=$(echo "$xml_content" | grep -i "set-backend-service" | sed -n 's/.*base-url="\([^"]*\)".*/\1/p' || true)
    if [[ -n "$backend_urls" ]]; then
        while IFS= read -r url; do
            if [[ "$url" =~ ^https?://localhost|^https?://127\.0\.0\.1|^https?://0\.0\.0\.0 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg t "$context: Backend URL Points to Localhost" \
                    --arg d "Backend service URL \`$url\` points to localhost - unreachable from APIM" \
                    --arg s "2" \
                    --arg n "Update backend URL to point to a publicly accessible endpoint" \
                    '.issues += [{
                       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                     }]')
            fi
        done <<< "$backend_urls"
    fi
}

###############################################################################
# Retrieve APIM resource ID
###############################################################################
apim_id=""
if ! apim_id=$(az apim show \
      --name "$APIM_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --query "id" -o tsv 2>apim_show_err.log); then
  err_msg=$(cat apim_show_err.log)
  rm -f apim_show_err.log
  echo "ERROR: Could not fetch APIM resource ID."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed to Retrieve APIM Resource ID" \
    --arg d "$err_msg" \
    --arg s "1" \
    --arg n "Check APIM name and RG or your permissions." \
    '.issues += [{
       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f apim_show_err.log

if [[ -z "$apim_id" ]]; then
  echo "[ERROR] No resource ID returned. Possibly APIM doesn't exist."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "APIM Resource Not Found" \
    --arg d "az apim show returned an empty ID." \
    --arg s "1" \
    --arg n "Confirm APIM name, resource group, or create APIM instance." \
    '.issues += [{
       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi

echo "[INFO] APIM Resource ID: $apim_id"

###############################################################################
# Check Global (Service-Level) Policy
###############################################################################
service_policy_url="https://management.azure.com${apim_id}/policies/policy?api-version=2022-08-01"
echo "[INFO] Checking service-level (global) policy..."

service_policy_xml=""
if ! service_policy_xml=$(az rest --method get --url "$service_policy_url" -o tsv --query "properties.value" 2>svc_policy_err.log || true); then
    error_msg=$(cat svc_policy_err.log 2>/dev/null || echo "Unknown error")
    if echo "$error_msg" | grep -i "unauthorized\|forbidden\|access denied" >/dev/null; then
        issues_json=$(echo "$issues_json" | jq \
            --arg t "Global Policy Access Denied" \
            --arg d "Cannot access global policy due to insufficient permissions: $error_msg" \
            --arg s "3" \
            --arg n "Grant proper RBAC permissions to read APIM policies" \
            '.issues += [{
               "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
             }]')
    fi
fi
rm -f svc_policy_err.log

if [[ -n "$service_policy_xml" ]]; then
    # Validate XML structure
    if ! validate_policy_xml "$service_policy_xml" "Global Policy"; then
        case $? in
            1)
                issues_json=$(echo "$issues_json" | jq \
                    --arg t "Global Policy XML Malformed" \
                    --arg d "Global policy contains malformed XML that will cause runtime errors" \
                    --arg s "1" \
                    --arg n "Fix XML syntax errors in the global policy configuration" \
                    '.issues += [{
                       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                     }]')
                ;;
            2)
                issues_json=$(echo "$issues_json" | jq \
                    --arg t "Global Policy Contains Error Keywords" \
                    --arg d "Global policy XML contains error-related keywords that may indicate issues" \
                    --arg s "3" \
                    --arg n "Review global policy for embedded error messages or exception handling" \
                    '.issues += [{
                       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                     }]')
                ;;
        esac
    fi
    
    # Check for specific authentication and backend issues
    check_auth_issues "$service_policy_xml" "Global Policy"
    check_backend_issues "$service_policy_xml" "Global Policy"
fi

###############################################################################
# Check API Policies
###############################################################################
echo "[INFO] Checking API policies..."
apis_json=$(az rest --method get --url "https://management.azure.com${apim_id}/apis?api-version=2022-08-01" -o json 2>/dev/null || echo "{}")
api_count=$(echo "$apis_json" | jq '.value | length' 2>/dev/null || echo 0)

for (( i=0; i<api_count; i++ )); do
    api_name=$(echo "$apis_json" | jq -r ".value[$i].name")
    api_id=$(echo "$apis_json" | jq -r ".value[$i].id")
    
    if [[ "$api_id" == "null" || -z "$api_id" ]]; then
        continue
    fi

    # Check API-level policy
    api_policy_url="https://management.azure.com${api_id}/policies/policy?api-version=2022-08-01"
    api_policy_xml=$(az rest --method get --url "$api_policy_url" -o tsv --query "properties.value" 2>/dev/null || echo "")
    
    if [[ -n "$api_policy_xml" ]]; then
        # Validate XML structure for API policy
        if ! validate_policy_xml "$api_policy_xml" "API $api_name"; then
            case $? in
                1)
                    issues_json=$(echo "$issues_json" | jq \
                        --arg t "API \`$api_name\` Policy XML Malformed" \
                        --arg d "API policy contains malformed XML that will cause runtime errors" \
                        --arg s "2" \
                        --arg n "Fix XML syntax errors in the API \`$api_name\` policy configuration" \
                        '.issues += [{
                           "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                         }]')
                    ;;
                2)
                    issues_json=$(echo "$issues_json" | jq \
                        --arg t "API \`$api_name\` Policy Contains Error Keywords" \
                        --arg d "API policy XML contains error-related keywords that may indicate issues" \
                        --arg s "3" \
                        --arg n "Review API \`$api_name\` policy for embedded error messages" \
                        '.issues += [{
                           "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                         }]')
                    ;;
            esac
        fi
        
        # Check for authentication and backend issues
        check_auth_issues "$api_policy_xml" "API \`$api_name\`"
        check_backend_issues "$api_policy_xml" "API \`$api_name\`"
    fi

    # Check operation-level policies
    api_ops_json=$(az rest --method get --url "https://management.azure.com${api_id}/operations?api-version=2022-08-01" -o json 2>/dev/null || echo "{}")
    op_count=$(echo "$api_ops_json" | jq '.value | length' 2>/dev/null || echo 0)
    
    for (( j=0; j<op_count; j++ )); do
        op_name=$(echo "$api_ops_json" | jq -r ".value[$j].name")
        op_id=$(echo "$api_ops_json" | jq -r ".value[$j].id")

        op_policy_url="https://management.azure.com${op_id}/policies/policy?api-version=2022-08-01"
        op_policy_xml=$(az rest --method get --url "$op_policy_url" -o tsv --query "properties.value" 2>/dev/null || echo "")
        
        if [[ -n "$op_policy_xml" ]]; then
            # Validate XML structure for operation policy
            if ! validate_policy_xml "$op_policy_xml" "Operation $op_name"; then
                case $? in
                    1)
                        issues_json=$(echo "$issues_json" | jq \
                            --arg t "Operation \`$op_name\` Policy XML Malformed" \
                            --arg d "Operation policy contains malformed XML that will cause runtime errors" \
                            --arg s "2" \
                            --arg n "Fix XML syntax errors in operation \`$op_name\` policy for API \`$api_name\`" \
                            '.issues += [{
                               "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                             }]')
                        ;;
                    2)
                        issues_json=$(echo "$issues_json" | jq \
                            --arg t "Operation \`$op_name\` Policy Contains Errors" \
                            --arg d "Operation policy XML contains error-related keywords" \
                            --arg s "3" \
                            --arg n "Review operation \`$op_name\` policy for error messages in API \`$api_name\`" \
                            '.issues += [{
                               "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                             }]')
                        ;;
                esac
            fi
            
            # Check for authentication and backend issues
            check_auth_issues "$op_policy_xml" "Operation \`$op_name\` in API \`$api_name\`"
            check_backend_issues "$op_policy_xml" "Operation \`$op_name\` in API \`$api_name\`"
        fi
    done
done

###############################################################################
# Check Product Policies
###############################################################################
echo "[INFO] Checking product policies..."
products_json=$(az rest --method get --url "https://management.azure.com${apim_id}/products?api-version=2022-08-01" -o json 2>/dev/null || echo "{}")
product_count=$(echo "$products_json" | jq '.value | length' 2>/dev/null || echo 0)

for (( i=0; i<product_count; i++ )); do
    product_name=$(echo "$products_json" | jq -r ".value[$i].name")
    product_id=$(echo "$products_json" | jq -r ".value[$i].id")
    
    if [[ "$product_id" == "null" || -z "$product_id" ]]; then
        continue
    fi

    product_policy_url="https://management.azure.com${product_id}/policies/policy?api-version=2022-08-01"
    product_policy_xml=$(az rest --method get --url "$product_policy_url" -o tsv --query "properties.value" 2>/dev/null || echo "")
    
    if [[ -n "$product_policy_xml" ]]; then
        # Validate XML structure for product policy
        if ! validate_policy_xml "$product_policy_xml" "Product $product_name"; then
            case $? in
                1)
                    issues_json=$(echo "$issues_json" | jq \
                        --arg t "Product \`$product_name\` Policy XML Malformed" \
                        --arg d "Product policy contains malformed XML that will cause runtime errors" \
                        --arg s "2" \
                        --arg n "Fix XML syntax errors in product \`$product_name\` policy configuration" \
                        '.issues += [{
                           "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                         }]')
                    ;;
                2)
                    issues_json=$(echo "$issues_json" | jq \
                        --arg t "Product \`$product_name\` Policy Contains Errors" \
                        --arg d "Product policy XML contains error-related keywords" \
                        --arg s "3" \
                        --arg n "Review product \`$product_name\` policy for embedded error messages" \
                        '.issues += [{
                           "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
                         }]')
                    ;;
            esac
        fi
        
        # Check for authentication and backend issues
        check_auth_issues "$product_policy_xml" "Product \`$product_name\`"
        check_backend_issues "$product_policy_xml" "Product \`$product_name\`"
    fi
done

###############################################################################
# Write results
###############################################################################
echo "$issues_json" > "$OUTPUT_FILE"
echo "[INFO] APIM policy verification complete. Results -> $OUTPUT_FILE"

# If no issues found, indicate healthy policies
total_issues=$(echo "$issues_json" | jq '.issues | length')
if [[ "$total_issues" -eq 0 ]]; then
    echo "[INFO] No policy-related issues detected in APIM \`$APIM_NAME\`"
fi
