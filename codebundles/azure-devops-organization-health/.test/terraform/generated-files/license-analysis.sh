#!/bin/bash

# Script to analyze Azure DevOps license utilization for testing
# Template variables will be replaced by Terraform

ORG_URL="${AZURE_DEVOPS_ORG_URL:-https://dev.azure.com/your-org}"
THRESHOLD="${LICENSE_UTILIZATION_THRESHOLD:-90}"

echo "Analyzing license utilization for organization"
echo "Organization URL: $ORG_URL"
echo "Threshold: $THRESHOLD%"

# Function to simulate license utilization analysis
analyze_license_utilization() {
    local org_url=$1
    local threshold=$2
    
    echo "Analyzing organization license utilization..."
    echo "Organization: $org_url"
    echo "Threshold: $threshold%"
    
    # Simulate license data
    local total_licenses=100
    local used_licenses=$((RANDOM % 30 + 70))  # Random between 70-100
    local utilization=$(( (used_licenses * 100) / total_licenses ))
    
    echo "Total licenses: $total_licenses"
    echo "Used licenses: $used_licenses"
    echo "Utilization: $utilization%"
    
    if [ $utilization -gt $threshold ]; then
        echo "WARNING: License utilization ($utilization%) exceeds threshold ($threshold%)"
        return 1
    else
        echo "INFO: License utilization within acceptable range"
        return 0
    fi
}

# Function to identify inactive users
identify_inactive_users() {
    local users=("$@")
    
    echo "Identifying inactive licensed users..."
    
    for user in "${users[@]}"; do
        # Simulate user activity check
        last_activity_days=$((RANDOM % 90 + 1))
        
        if [ $last_activity_days -gt 30 ]; then
            echo "INACTIVE: User '$user' - Last activity: $last_activity_days days ago"
        else
            echo "ACTIVE: User '$user' - Last activity: $last_activity_days days ago"
        fi
    done
}

# Function to check for misaligned access levels
check_access_alignment() {
    local users=("$@")
    
    echo "Checking access level alignment..."
    
    # Define access patterns
    local access_types=("basic" "stakeholder" "visualStudioProfessional" "visualStudioEnterprise")
    local usage_patterns=("high" "medium" "low" "none")
    
    for user in "${users[@]}"; do
        # Simulate access level and usage analysis
        assigned_access=${access_types[$((RANDOM % ${#access_types[@]}))]}
        actual_usage=${usage_patterns[$((RANDOM % ${#usage_patterns[@]}))]}
        
        echo "User: $user"
        echo "  Assigned Access: $assigned_access"
        echo "  Actual Usage: $actual_usage"
        
        # Check for misalignment
        case "$assigned_access" in
            "visualStudioEnterprise"|"visualStudioProfessional")
                if [ "$actual_usage" == "none" ] || [ "$actual_usage" == "low" ]; then
                    echo "  MISALIGNED: High-tier license with low/no usage"
                fi
                ;;
            "basic")
                if [ "$actual_usage" == "none" ]; then
                    echo "  MISALIGNED: Basic license with no usage"
                fi
                ;;
            "stakeholder")
                if [ "$actual_usage" == "high" ]; then
                    echo "  MISALIGNED: Stakeholder license with high usage (consider upgrade)"
                fi
                ;;
        esac
        echo ""
    done
}

# Function to calculate license optimization opportunities
calculate_optimization() {
    local users=("$@")
    local total_users=${#users[@]}
    
    echo "Calculating license optimization opportunities..."
    
    # Simulate optimization analysis
    local potential_downgrades=$((RANDOM % 5 + 1))
    local potential_removals=$((RANDOM % 3 + 1))
    local estimated_savings=$(( (potential_downgrades * 20) + (potential_removals * 50) ))
    
    echo "Optimization Summary:"
    echo "  Total users analyzed: $total_users"
    echo "  Potential downgrades: $potential_downgrades users"
    echo "  Potential removals: $potential_removals users"
    echo "  Estimated monthly savings: \$$estimated_savings"
    
    if [ $estimated_savings -gt 100 ]; then
        echo "  RECOMMENDATION: Significant optimization opportunity identified"
    fi
}

# Function to check Visual Studio subscriber usage
check_vs_subscriber_usage() {
    echo "Checking Visual Studio subscriber license usage..."
    
    # Simulate VS subscriber analysis
    local vs_subscribers=$((RANDOM % 10 + 5))
    local vs_unused=$((RANDOM % 3))
    
    echo "Visual Studio Subscribers: $vs_subscribers"
    echo "Unused VS benefits: $vs_unused"
    
    if [ $vs_unused -gt 0 ]; then
        echo "WARNING: $vs_unused Visual Studio subscribers not utilizing benefits"
        echo "Consider training or license reallocation"
    fi
}

# Main execution
main() {
    echo "Starting license utilization analysis"
    echo "Organization: $ORG_URL"
    echo "Threshold: $THRESHOLD%"
    echo "----------------------------------------"
    
    # Analyze overall utilization
    if ! analyze_license_utilization "$ORG_URL" $THRESHOLD; then
        echo "LICENSE THRESHOLD EXCEEDED - Investigation required"
    fi
    
    echo ""
    
    # Query organization users (this would use Azure DevOps CLI in real implementation)
    echo "Querying organization users..."
    # In real implementation: az devops user list --organization "$ORG_URL"
    # For testing, simulate with sample users
    ORG_USERS=("user1@contoso.com" "user2@contoso.com" "user3@contoso.com" "inactive-user@contoso.com")
    
    # Check for inactive users
    identify_inactive_users "${ORG_USERS[@]}"
    
    echo ""
    
    # Check access alignment
    check_access_alignment "${ORG_USERS[@]}"
    
    echo ""
    
    # Calculate optimization opportunities
    calculate_optimization "${ORG_USERS[@]}"
    
    echo ""
    
    # Check VS subscriber usage
    check_vs_subscriber_usage
    
    echo ""
    echo "License analysis completed"
    echo "Review output for optimization opportunities"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 