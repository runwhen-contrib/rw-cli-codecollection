#!/bin/bash
# Test script for task inactivity timeout monitoring
# This script simulates different task behaviors to test timeout scenarios

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Task Inactivity Timeout Test Script ===${NC}"
echo ""

# Get scenario from argument or default to help
SCENARIO=${1:-help}

show_help() {
    echo "Usage: $0 <scenario>"
    echo ""
    echo "Available scenarios:"
    echo "  active       - Task that produces continuous output (SHOULD NOT timeout)"
    echo "  inactive     - Task that goes silent after initial output (SHOULD timeout)"
    echo "  sporadic     - Task with occasional output bursts"
    echo "  long-silent  - Task with long pauses between outputs"
    echo "  mixed        - Combination of active and inactive periods"
    echo ""
    echo "Environment variables for testing:"
    echo "  TASK_TOTAL_TIMEOUT_MINUTES       - Default: 30 minutes"
    echo "  TASK_INACTIVITY_TIMEOUT_MINUTES  - Default: 10 minutes"
    echo ""
    echo "Example for quick testing (2 min total, 30 sec inactivity):"
    echo "  export TASK_TOTAL_TIMEOUT_MINUTES=2"
    echo "  export TASK_INACTIVITY_TIMEOUT_MINUTES=0.5  # 30 seconds"
    echo "  $0 inactive"
    echo ""
}

# Scenario 1: Active task with continuous output
scenario_active() {
    echo -e "${GREEN}Scenario: Active Task (Continuous Output)${NC}"
    echo "This task produces output regularly and should NOT timeout due to inactivity"
    echo "---"
    
    for i in {1..100}; do
        echo "[$(date '+%H:%M:%S')] Processing item $i of 100..."
        echo "  - Analyzing data..."
        echo "  - Running calculations..."
        echo "  - Saving results..."
        sleep 5  # Produce output every 5 seconds
    done
    
    echo -e "${GREEN}✓ Task completed successfully${NC}"
}

# Scenario 2: Inactive task that goes silent
scenario_inactive() {
    echo -e "${RED}Scenario: Inactive Task (Goes Silent)${NC}"
    echo "This task produces initial output then goes silent"
    echo "Should timeout after TASK_INACTIVITY_TIMEOUT_MINUTES"
    echo "---"
    
    echo "[$(date '+%H:%M:%S')] Starting task..."
    echo "Loading configuration..."
    echo "Initializing resources..."
    echo "Beginning processing..."
    echo ""
    
    echo -e "${YELLOW}⚠️  Now entering silent period (no output)${NC}"
    echo "[$(date '+%H:%M:%S')] Last output before silence"
    
    # Go silent for 15 minutes (should trigger 10-minute inactivity timeout)
    sleep 900
    
    # This should never be reached if timeout is working
    echo "[$(date '+%H:%M:%S')] Task completed (THIS SHOULD NOT BE REACHED)"
}

# Scenario 3: Sporadic output
scenario_sporadic() {
    echo -e "${YELLOW}Scenario: Sporadic Output${NC}"
    echo "Task with irregular bursts of output"
    echo "Behavior depends on pause duration vs inactivity timeout"
    echo "---"
    
    for round in {1..5}; do
        echo ""
        echo "[$(date '+%H:%M:%S')] === Round $round of 5 ==="
        
        # Active burst
        for i in {1..5}; do
            echo "  Processing batch item $i..."
            sleep 1
        done
        
        echo "[$(date '+%H:%M:%S')] Batch complete. Waiting for next batch..."
        
        # Pause between bursts (adjust this to test)
        # If this is > TASK_INACTIVITY_TIMEOUT_MINUTES, task will timeout
        PAUSE_SECONDS=60
        echo "  (pausing for ${PAUSE_SECONDS}s)"
        sleep $PAUSE_SECONDS
    done
    
    echo -e "${GREEN}✓ All rounds completed${NC}"
}

# Scenario 4: Long silent periods
scenario_long_silent() {
    echo -e "${YELLOW}Scenario: Long Silent Periods${NC}"
    echo "Task with extended processing that produces no output"
    echo "Common in data processing, model training, etc."
    echo "---"
    
    tasks=("Data Loading" "Data Preprocessing" "Heavy Computation" "Model Training" "Result Generation")
    
    for task in "${tasks[@]}"; do
        echo "[$(date '+%H:%M:%S')] Starting: $task"
        
        # Simulate long-running task with no output
        # For testing, use shorter durations
        SILENT_DURATION=180  # 3 minutes
        echo "  Working... (this will take ${SILENT_DURATION}s with no output)"
        sleep $SILENT_DURATION
        
        echo "[$(date '+%H:%M:%S')] Completed: $task"
    done
    
    echo -e "${GREEN}✓ All tasks completed${NC}"
}

# Scenario 5: Mixed behavior
scenario_mixed() {
    echo -e "${BLUE}Scenario: Mixed Behavior${NC}"
    echo "Task that alternates between active and potentially inactive periods"
    echo "---"
    
    # Phase 1: Active
    echo ""
    echo "[$(date '+%H:%M:%S')] Phase 1: Active processing"
    for i in {1..10}; do
        echo "  Item $i processing..."
        sleep 2
    done
    
    # Phase 2: Moderately silent
    echo ""
    echo "[$(date '+%H:%M:%S')] Phase 2: Background processing (90s silent)"
    sleep 90
    echo "[$(date '+%H:%M:%S')] Background processing complete"
    
    # Phase 3: Active again
    echo ""
    echo "[$(date '+%H:%M:%S')] Phase 3: Generating reports"
    for i in {1..5}; do
        echo "  Report $i generated"
        sleep 3
    done
    
    # Phase 4: Critically silent (should timeout if > inactivity threshold)
    echo ""
    echo "[$(date '+%H:%M:%S')] Phase 4: Final validation (long silent period)"
    echo -e "${YELLOW}⚠️  Entering extended silent period (12 minutes)${NC}"
    sleep 720
    
    echo "[$(date '+%H:%M:%S')] Validation complete (SHOULD NOT BE REACHED)"
}

# Show current timeout configuration
show_config() {
    echo -e "${BLUE}Current Timeout Configuration:${NC}"
    TOTAL=${TASK_TOTAL_TIMEOUT_MINUTES:-30}
    INACTIVITY=${TASK_INACTIVITY_TIMEOUT_MINUTES:-10}
    
    echo "  TASK_TOTAL_TIMEOUT_MINUTES:      ${TOTAL} minutes"
    echo "  TASK_INACTIVITY_TIMEOUT_MINUTES: ${INACTIVITY} minutes"
    echo ""
    
    # Calculate seconds for clarity
    TOTAL_SECONDS=$((${TOTAL%.*} * 60))
    INACTIVITY_SECONDS=$(echo "$INACTIVITY * 60" | bc)
    echo "  Total timeout:      ${TOTAL_SECONDS}s"
    echo "  Inactivity timeout: ${INACTIVITY_SECONDS%.*}s"
    echo ""
}

# Main execution
case "$SCENARIO" in
    active)
        show_config
        scenario_active
        ;;
    inactive)
        show_config
        scenario_inactive
        ;;
    sporadic)
        show_config
        scenario_sporadic
        ;;
    long-silent)
        show_config
        scenario_long_silent
        ;;
    mixed)
        show_config
        scenario_mixed
        ;;
    help|--help|-h)
        show_help
        exit 0
        ;;
    *)
        echo -e "${RED}Error: Unknown scenario '$SCENARIO'${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac

