#!/bin/bash

# Function to format section header
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

# Get the command history
if [ -f "command_history.txt" ]; then
    print_section_header "Commands Used"
    cat command_history.txt
    echo
fi

# Get the check results
print_section_header "Namespace Analysis"

# Process each namespace's results
if [ -f "report.txt" ]; then
    # Add summary section
    # print_section_header "Summary"
    # TOTAL_NS=$(grep -c "=== Analyzing namespace:" report.txt)
    # # Get list of namespaces without injection
    # NAMESPACES_WITHOUT_INJECTION=$(grep -B1 "Namespace does not have injection enabled" report.txt | grep "=== Analyzing namespace:" | sed -e 's/=== Analyzing namespace: //g' | tr '\n' ',' | sed 's/,$//')
    
    # # Get deployment counts by status
    # TOTAL_SUCCESS=$(grep -c "✓.*sidecar properly configured" report.txt)
    # TOTAL_ISSUES=$(grep -c "WARNING.*No pods have sidecar\|WARNING.*No sidecar found" report.txt)
    # # Count deployments where both namespace doesn't have injection and no annotation exists
    # TOTAL_NOT_CONFIGURED=$(grep -c "❌ Deployment '.*' in namespace '.*' is NOT properly configured" report.txt)
    
    # # Get lists of deployments by status
    # DEPLOYMENTS_WITH_SIDECAR=$(grep "✓.*sidecar properly configured" report.txt | sed -e 's/.*Deployment '\''//g' -e "s/'\'' in namespace.*//g" | tr '\n' ',' | sed 's/,$//')
    # DEPLOYMENTS_MISSING_SIDECAR=$(grep "WARNING.*No pods have sidecar\|WARNING.*No sidecar found" report.txt | sed -e 's/.*Deployment //g' -e "s/ in namespace.*//g" | tr '\n' ',' | sed 's/,$//')
    # # Get deployments not configured for injection (both namespace and deployment level)
    # DEPLOYMENTS_NOT_CONFIGURED=$(grep "❌ Deployment '.*' in namespace '.*' is NOT properly configured" report.txt | \
    #     sed -E "s/❌ Deployment '(.*)' in namespace '(.*)' is NOT properly configured.*/\1 (\2)/" | \
    #     paste -sd ',' -)
    

    # echo "Namespace Analysis:"
    # echo "  - Total namespaces analyzed: $TOTAL_NS"
    # if [ -n "$NAMESPACES_WITHOUT_INJECTION" ]; then
    #     echo "  - Namespaces without injection enabled: $NAMESPACES_WITHOUT_INJECTION"
    # fi
    # echo
    # echo "Deployment Status:"
    # echo "  - Deployments with sidecar properly configured: $TOTAL_SUCCESS"
    # if [ -n "$DEPLOYMENTS_WITH_SIDECAR" ]; then
    #     echo "    Deployments: $DEPLOYMENTS_WITH_SIDECAR"
    # fi
    # echo "  - Deployments with missing sidecar: $TOTAL_ISSUES"
    # if [ -n "$DEPLOYMENTS_MISSING_SIDECAR" ]; then
    #     echo "    Deployments: $DEPLOYMENTS_MISSING_SIDECAR"
    # fi
    # echo "  - Deployments not configured for injection: $TOTAL_NOT_CONFIGURED"
    # echo "DEBUG: DEPLOYMENTS_NOT_CONFIGURED='$DEPLOYMENTS_NOT_CONFIGURED'"
    # if [ -n "$DEPLOYMENTS_NOT_CONFIGURED" ]; then
    #     echo "    Deployments (namespace): $DEPLOYMENTS_NOT_CONFIGURED"
    #     echo "    Note: These deployments are in namespaces without injection enabled and have no injection annotation"
    # fi
    
    print_section_header "Summary"

    TOTAL_NS=$(grep -c "=== Analyzing namespace:" report.txt)
    NAMESPACES_WITHOUT_INJECTION=$(grep -B1 "Namespace does not have injection enabled" report.txt | grep "=== Analyzing namespace:" | sed -e 's/=== Analyzing namespace: //g' | tr '\n' ',' | sed 's/,$//')

    TOTAL_SUCCESS=$(grep -c "✓.*sidecar properly configured" report.txt)
    TOTAL_ISSUES=$(grep -c "WARNING.*No pods have sidecar\|WARNING.*No sidecar found" report.txt)
    TOTAL_NOT_CONFIGURED=$(grep -c "❌ Deployment '.*' in namespace '.*' is NOT properly configured" report.txt)

    DEPLOYMENTS_WITH_SIDECAR=$(grep "✓.*sidecar properly configured" report.txt | sed -E "s/.*Deployment '(.*)' in namespace '(.*)' has sidecar properly configured.*/\1|\2/" | column -t -s '|')
    DEPLOYMENTS_MISSING_SIDECAR=$(grep "WARNING.*No pods have sidecar\|WARNING.*No sidecar found" report.txt | sed -E "s/WARNING.*Deployment '(.*)' in namespace '(.*)' has no sidecar.*/\1|\2/" | column -t -s '|')
    DEPLOYMENTS_NOT_CONFIGURED=$(grep --color=never "✓" report.txt | sed -E "s/.*Deployment '(.*)' in namespace '(.*)' has sidecar properly configured.*/\1|\2/" | column -t -s '|')


    # Print summary in tabular format
    echo
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
        echo "$DEPLOYMENTS_WITH_SIDECAR"
        echo
    fi

    if [ -n "$DEPLOYMENTS_MISSING_SIDECAR" ]; then
        echo "=============================================================="
        echo "                Deployments Missing Sidecar                   "
        echo "=============================================================="
        printf "%-35s %-25s\n" "Deployment Name" "Namespace"
        echo "--------------------------------------------------------------"
        echo "$DEPLOYMENTS_MISSING_SIDECAR"
        echo
    fi

    if [ -n "$DEPLOYMENTS_NOT_CONFIGURED" ]; then
        echo "=============================================================="
        echo "             Deployments Not Properly Configured              "
        echo "=============================================================="
        printf "%-35s %-25s\n" "Deployment Name" "Namespace"
        echo "--------------------------------------------------------------"
        echo "$DEPLOYMENTS_NOT_CONFIGURED"
        echo
        echo
        echo "Note: These deployments are in namespaces without injection enabled and have no injection annotation."
        echo
    fi


    while IFS= read -r line; do
    # If line starts with === it's a namespace header
    if [[ $line == "==="* ]]; then
        echo
        echo "$line"
    # If line starts with WARNING it's an issue
    elif [[ $line == "WARNING"* ]]; then
        echo "⚠️  $line"
    # If line starts with Error it's an error
    elif [[ $line == "Error"* ]]; then
        echo "❌ $line"
    # If line starts with ✓ it's a success
    elif [[ $line == "✓"* ]]; then
        echo "✅ $line"
    # If line starts with ℹ it's informational
    elif [[ $line == "ℹ"* ]]; then
        echo "ℹ️  $line"
    else
        echo "   $line"
    fi
    done < report.txt

else
    echo "No report file found."
fi 


