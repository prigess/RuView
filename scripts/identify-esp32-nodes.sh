#!/usr/bin/env bash
# Identify ESP32 nodes by reading their serial output
# Usage: ./identify-esp32-nodes.sh [port]
#
# If no port specified, scans all connected ESP32 devices.

set -euo pipefail

BAUD=115200
TIMEOUT=5

identify_node() {
    local port="$1"
    echo "=== Checking ${port} ==="

    # Send a newline to trigger output, then read for TIMEOUT seconds
    # Look for node_id in the boot log or status output
    timeout ${TIMEOUT}s python3 -c "
import serial
import sys
import time

try:
    ser = serial.Serial('$port', $BAUD, timeout=1)
    # Trigger a reset by toggling DTR
    ser.dtr = False
    time.sleep(0.1)
    ser.dtr = True

    # Read for a few seconds
    start = time.time()
    while time.time() - start < 4:
        line = ser.readline().decode('utf-8', errors='ignore').strip()
        if line:
            # Look for node_id in various formats
            if 'node_id' in line.lower() or 'NODE_ID' in line:
                print(f'FOUND: {line}')
            elif 'mmWave sensor' in line:
                print(f'RADAR: {line}')
            elif 'WiFi connected' in line:
                print(f'WIFI: {line}')
    ser.close()
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null || echo "  (timeout or error)"
    echo ""
}

# Get list of ports
if [ $# -gt 0 ]; then
    PORTS=("$1")
else
    # Find all ESP32 USB serial ports
    PORTS=($(ls /dev/cu.wchusbserial* /dev/cu.usbserial* /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true))
fi

if [ ${#PORTS[@]} -eq 0 ]; then
    echo "No ESP32 devices found."
    echo ""
    echo "On macOS: /dev/cu.wchusbserial* or /dev/cu.usbserial*"
    echo "On Linux: /dev/ttyUSB* or /dev/ttyACM*"
    exit 1
fi

echo "Found ${#PORTS[@]} device(s). Reading node info..."
echo ""

for port in "${PORTS[@]}"; do
    identify_node "$port"
done

echo "=== Done ==="
echo ""
echo "To re-provision a node with a new ID:"
echo "  python provision.py --port <PORT> --ssid <SSID> --password <PASS> --target-ip <IP> --node-id <N>"
