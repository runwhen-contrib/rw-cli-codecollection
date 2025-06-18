#!/bin/bash

# Script to generate load on Azure DevOps agent pools for testing
# Template variables will be replaced by Terraform

POOL_NAME="offline-agents-pool-d5a1bb4d"
ORG_URL="https://dev.azure.com/runwhen-labs"
PROJECTS=("cross-dependencies-project-d5a1bb4d" "high-capacity-project-d5a1bb4d" "license-test-project-d5a1bb4d" "security-test-project-d5a1bb4d" "service-health-project-d5a1bb4d")

echo "Generating load on agent pool: $POOL_NAME"
echo "Organization URL: $ORG_URL"
echo "Target projects: ${PROJECTS[@]}"

# Function to queue builds to create agent load
queue_test_builds() {
    local project=$1
    local build_count=${2:-5}
    
    echo "Queuing $build_count builds in project: $project"
    
    for i in $(seq 1 $build_count); do
        echo "Queuing build $i for $project"
        
        # This would typically use Azure DevOps CLI or REST API
        # az devops build queue --project "$project" --definition-name "load-test-build"
        
        # Simulate build queuing with a placeholder
        echo "BUILD_QUEUED: Project=$project, Build=$i, Pool=$POOL_NAME"
        sleep 1
    done
}

# Function to monitor agent pool utilization
monitor_pool_utilization() {
    local pool_name=$1
    local duration=${2:-300}  # Monitor for 5 minutes by default
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    
    echo "Monitoring pool '$pool_name' utilization for $duration seconds"
    
    while [ $(date +%s) -lt $end_time ]; do
        current_time=$(date '+%Y-%m-%d %H:%M:%S')
        
        # This would typically query the Azure DevOps API for actual utilization
        # utilization=$(az devops agent pool show --pool-id "$pool_id" --query "utilization")
        
        # Simulate utilization monitoring
        utilization=$((RANDOM % 40 + 60))  # Random value between 60-100
        echo "[$current_time] Pool '$pool_name' utilization: $utilization%"
        
        if [ $utilization -gt 85 ]; then
            echo "WARNING: High utilization detected ($utilization%)"
        fi
        
        sleep 30
    done
}

# Function to simulate offline agents
simulate_offline_agents() {
    local pool_name=$1
    local offline_count=${2:-2}
    
    echo "Simulating $offline_count offline agents in pool: $pool_name"
    
    # This would typically disable agents via Azure DevOps API
    for i in $(seq 1 $offline_count); do
        echo "SIMULATED: Agent $i in pool '$pool_name' is now offline"
    done
}

# Main execution
main() {
    echo "Starting agent load generation test"
    echo "Pool: $POOL_NAME"
    echo "Organization: $ORG_URL"
    echo "----------------------------------------"
    
    # Queue builds across all test projects
    for project in "${PROJECTS[@]}"; do
        queue_test_builds "$project" 3
    done
    
    # Start monitoring in background
    monitor_pool_utilization "$POOL_NAME" 600 &
    MONITOR_PID=$!
    
    # Simulate some offline agents
    simulate_offline_agents "$POOL_NAME" 2
    
    echo "Load generation complete"
    echo "Monitoring process PID: $MONITOR_PID"
    echo "Kill monitoring with: kill $MONITOR_PID"
    
    # Wait for monitoring to complete or be interrupted
    wait $MONITOR_PID
    
    echo "Agent load test completed for pool: $POOL_NAME"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 