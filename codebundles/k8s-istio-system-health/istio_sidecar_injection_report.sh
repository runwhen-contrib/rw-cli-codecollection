#!/bin/bash

# Function to format section header
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

function print_section_header() {
    echo "=== $1 ==="
    echo
}

# Function to format command output
function format_command_output() {
    local cmd="$1"
    local output="$2"
    echo "Command: $cmd"
    echo "Output:"
    echo "$output"
    echo
}

# Start building the report
print_section_header "Istio Sidecar Injection Status Check"

# Set the report file path
REPORT_FILE="report.txt"

# Process each namespace's results
if [ -f $REPORT_FILE ]; then
    
    print_section_header "Summary"

    TOTAL_NS=$(grep -c "=== Analyzing namespace:" $REPORT_FILE)
    NAMESPACES_WITHOUT_INJECTION=$(grep -B4 "Namespace does not have injection enabled" $REPORT_FILE | grep "=== Analyzing namespace:" | sed -E 's/=== Analyzing namespace: (.*) ===/\1/' | tr '\n' ',' | sed 's/,$//')

    TOTAL_SUCCESS=$(grep -c "Deployment '.*' in namespace '.*' .* Istio sidecar properly configured" $REPORT_FILE)
    TOTAL_ISSUES=$(grep -c "Deployment '.*' in namespace '.*' is missing Istio sidecar" $REPORT_FILE)
    TOTAL_NOT_CONFIGURED=$(grep -c "Deployment '.*' in namespace '.*' is NOT properly configured" $REPORT_FILE)

    DEPLOYMENTS_WITH_SIDECAR=$(grep "Deployment '.*' in namespace '.*' .* Istio sidecar properly configured" $REPORT_FILE | sed -E "s/.*Deployment '(.*)' in namespace '(.*)' .* Istio sidecar properly configured.*/\1|\2/" | column -t -s '|')
    DEPLOYMENTS_MISSING_SIDECAR=$(grep "Deployment '.*' in namespace '.*' is missing Istio sidecar" $REPORT_FILE | sed -E "s/.*Deployment '(.*)' in namespace '(.*)' is missing Istio sidecar.*/\1|\2/" | column -t -s '|')
    DEPLOYMENTS_NOT_CONFIGURED=$(grep "Deployment '.*' in namespace '.*' is NOT properly configured" $REPORT_FILE | sed -E "s/.*Deployment '(.*)' in namespace '(.*)' is NOT properly configured.*/\1|\2/" | column -t -s '|')


    # Print summary in tabular format
    echo "=============================================================="
    echo "                        SUMMARY REPORT                        "
    echo "=============================================================="
    printf "%-45s %-10s\n" "Metric" "Count"
    echo "--------------------------------------------------------------"
    printf "%-45s %-10s\n" "Total Namespaces Analyzed" "$TOTAL_NS"
    printf "%-45s %-10s\n" "Deployments with Sidecar" "$TOTAL_SUCCESS"
    printf "%-45s %-10s\n" "Deployments Missing Sidecar" "$TOTAL_ISSUES"
    printf "%-45s %-10s\n" "Deployments Not Configured for Injection" "$TOTAL_NOT_CONFIGURED"
    echo "--------------------------------------------------------------"
    echo

    if [ -n "$NAMESPACES_WITHOUT_INJECTION" ]; then
        echo "=============================================================="
        echo "                Namespaces without Injection                 "
        echo "=============================================================="
        echo "$NAMESPACES_WITHOUT_INJECTION"
        echo
    fi

    if [ -n "$DEPLOYMENTS_WITH_SIDECAR" ]; then
        echo "=============================================================="
        echo "                  Deployments with Sidecar                    "
        echo "=============================================================="
        printf "%-35s %-25s\n" "Deployment Name" "Namespace"
        echo "--------------------------------------------------------------"
        echo "$DEPLOYMENTS_WITH_SIDECAR" | awk '{printf "%-35s %-25s\n", $1, $2}'
        echo
    fi

    if [ -n "$DEPLOYMENTS_MISSING_SIDECAR" ]; then
        echo "=============================================================="
        echo "                Deployments Missing Sidecar                   "
        echo "=============================================================="
        printf "%-35s %-25s\n" "Deployment Name" "Namespace"
        echo "--------------------------------------------------------------"
        echo "$DEPLOYMENTS_MISSING_SIDECAR" | awk '{printf "%-35s %-25s\n", $1, $2}'
        echo
    fi

    if [ -n "$DEPLOYMENTS_NOT_CONFIGURED" ]; then
        echo "=============================================================="
        echo "             Deployments Not Properly Configured              "
        echo "=============================================================="
        printf "%-35s %-25s\n" "Deployment Name" "Namespace"
        echo "--------------------------------------------------------------"
        echo "$DEPLOYMENTS_NOT_CONFIGURED" | awk '{printf "%-35s %-25s\n", $1, $2}'
        echo
        echo
        echo "Note: These deployments are in namespaces without injection enabled and have no injection annotation."
        echo
    fi

    echo
    echo
    print_section_header "Namespace Analysis"

    while IFS= read -r line; do
        # Skip "=== Deployment Summary ==="
        if [[ "$line" == "=== Deployment Summary ===" ]]; then
            continue
        fi
        # If line starts with === it's a namespace header
        if [[ $line == "==="* ]]; then
            echo
            echo "$line"
        # If line starts with WARNING it's an issue
        elif [[ $line == "WARNING"* ]]; then
            echo "$line"
        # If line starts with Error it's an error
        elif [[ $line == "Error"* ]]; then
            echo "$line"
        else
            echo "$line"
        fi
    done < $REPORT_FILE

else
    echo "No report file found."
fi 


