#!/bin/bash
# Simple test script for worker timeout behavior

MODE=${1:-help}

case "$MODE" in
    active)
        echo "Mode: ACTIVE - Task with continuous output (should NOT timeout)"
        echo "Running for 12 minutes with output every 5 seconds..."
        echo "(This proves task continues past 10 min inactivity threshold)"
        echo ""
        for i in {1..144}; do
            echo "[$(date '+%H:%M:%S')] Progress: $((i * 5))s / 720s"
            sleep 5
        done
        echo ""
        echo "✓ Completed successfully after 12 minutes"
        ;;
        
    inactive)
        echo "Mode: INACTIVE - Task that goes silent (SHOULD timeout)"
        echo "[$(date '+%H:%M:%S')] Starting..."
        sleep 2
        echo "[$(date '+%H:%M:%S')] Going silent for 15 minutes..."
        echo "(Should timeout after 10 min with default settings)"
        echo ""
        sleep 900
        echo "ERROR: Should have timed out!"
        exit 1
        ;;
        
    *)
        echo "Usage: $0 [active|inactive]"
        echo ""
        echo "  active   - Runs for 12 minutes with output every 5s (should NOT timeout)"
        echo "  inactive - Goes silent for 15 min (should timeout after 10 min)"
        echo ""
        echo "Quick test (30 second timeout):"
        echo "  export TASK_INACTIVITY_TIMEOUT_MINUTES=0.5"
        echo "  $0 inactive"
        exit 1
        ;;
esac

