#!/bin/bash
# Simple test script for worker timeout behavior

MODE=${1:-help}

case "$MODE" in
    active)
        echo "Mode: ACTIVE - Task with continuous output (should complete)"
        for i in {1..24}; do
            echo "[$(date '+%H:%M:%S')] Progress: $((i * 5))s"
            sleep 5
        done
        echo "✓ Completed successfully"
        ;;
        
    inactive)
        echo "Mode: INACTIVE - Task that goes silent (should timeout)"
        echo "[$(date '+%H:%M:%S')] Starting..."
        sleep 2
        echo "[$(date '+%H:%M:%S')] Going silent for 15 minutes..."
        sleep 900
        echo "ERROR: Should have timed out!"
        exit 1
        ;;
        
    *)
        echo "Usage: $0 [active|inactive]"
        echo ""
        echo "  active   - Produces output every 5s for 2 minutes (completes successfully)"
        echo "  inactive - Goes silent for 15 minutes (times out after 10 min default)"
        echo ""
        echo "Quick test (30 second timeout):"
        echo "  export TASK_INACTIVITY_TIMEOUT_MINUTES=0.5"
        echo "  $0 inactive"
        exit 1
        ;;
esac

