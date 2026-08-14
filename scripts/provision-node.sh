#!/bin/bash
# Provision WiFi credentials on an ESP32-S3 node

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PORT="${1:-/dev/ttyUSB0}"
SSID="${2}"
PASSWORD="${3}"
TARGET_IP="${4:-192.168.1.100}"
TARGET_PORT="${5:-5005}"

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    echo "Usage: $0 <port> <ssid> <password> [target_ip] [target_port]"
    echo ""
    echo "Examples:"
    echo "  $0 /dev/ttyUSB0 \"MyWiFi\" \"MyPassword\" 192.168.1.100"
    echo "  $0 COM3 \"MyWiFi\" \"MyPassword\" 192.168.1.100 5005"
    exit 1
fi

if [ ! -e "$PORT" ]; then
    echo "Error: Port $PORT not found!"
    exit 1
fi

echo "Provisioning ESP32-S3 on $PORT..."
echo "  SSID: $SSID"
echo "  Target: $TARGET_IP:$TARGET_PORT"
echo ""

# Use the provision.py script
python "$REPO_ROOT/firmware/esp32-csi-node/provision.py" \
    --port "$PORT" \
    --ssid "$SSID" \
    --password "$PASSWORD" \
    --target-ip "$TARGET_IP:$TARGET_PORT"

echo ""
echo "Provisioning complete!"
echo ""
echo "The device will now connect to WiFi and start sending CSI data."
echo "Monitor with: python -m serial.tools.miniterm $PORT 115200"
