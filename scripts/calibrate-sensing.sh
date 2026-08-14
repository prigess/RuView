#!/usr/bin/env bash
# Calibrate RuView sensing server with training recordings
# Usage: ./calibrate-sensing.sh [target_host]
#
# This script creates labeled recordings for classifier training.
# Run with an empty room first, then with people at various activity levels.

set -euo pipefail

TARGET_HOST="${1:-192.168.7.205}"
API_BASE="http://${TARGET_HOST}:3022/api/v1"

echo "=== RuView Sensing Calibration ==="
echo "Target: ${TARGET_HOST}"
echo ""

# Function to start/stop recording
record() {
    local label="$1"
    local duration="$2"
    local description="$3"

    echo ""
    echo "Recording: ${label} (${duration}s)"
    echo "Description: ${description}"
    read -p "Press Enter when ready to start recording, or 's' to skip: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Ss]$ ]]; then
        echo "Skipped."
        return
    fi

    # Start recording
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"session_name\": \"train_${label}\", \"label\": \"${label}\", \"duration_secs\": ${duration}}" \
        "${API_BASE}/recording/start" | jq .

    echo "Recording for ${duration}s... ${description}"
    sleep "${duration}"

    # Stop recording
    curl -s -X POST "${API_BASE}/recording/stop" | jq .
    echo "Recording complete."
}

echo "This will create 4 training recordings for the classifier."
echo "Follow the instructions for each recording."
echo ""

# 1. Empty room
record "absent" 120 "Keep room EMPTY. No movement, no people."

# 2. One person sitting still
record "present_still" 120 "ONE person sitting still. Minimal movement. Normal breathing."

# 3. One person moving
record "present_moving" 120 "ONE person walking around slowly. Normal activity."

# 4. Active movement
record "active" 120 "ONE or TWO people with active movement. Walking, gesturing."

echo ""
echo "=== Recordings complete ==="
echo ""
echo "To train the classifier, run:"
echo "  curl -X POST ${API_BASE}/adaptive/train"
echo ""
echo "To verify recordings:"
echo "  curl -s ${API_BASE}/recording/list | jq '.[] | {id, label, frame_count}'"
