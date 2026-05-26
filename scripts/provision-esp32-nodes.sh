#!/usr/bin/env bash
# Provision multiple ESP32-S3 CSI nodes
# Usage: ./provision-esp32-nodes.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVISION_SCRIPT="${REPO_ROOT}/firmware/esp32-csi-node/provision.py"

# Target aggregator (Orange Pi)
TARGET_IP="${TARGET_IP:-192.168.7.205}"
TARGET_PORT="${TARGET_PORT:-5005}"

echo "=== ESP32-S3 CSI Node Provisioning ==="
echo "Target aggregator: ${TARGET_IP}:${TARGET_PORT}"
echo ""

# Get WiFi credentials
read -p "WiFi SSID: " WIFI_SSID
read -sp "WiFi Password: " WIFI_PASS
echo ""

# Detect connected ESP32s
PORTS=($(ls /dev/cu.wchusbserial* 2>/dev/null || true))
if [ ${#PORTS[@]} -eq 0 ]; then
    echo "Error: No ESP32 devices found. Check USB connections."
    exit 1
fi

echo ""
echo "Found ${#PORTS[@]} ESP32 device(s):"
for i in "${!PORTS[@]}"; do
    echo "  [$((i+1))] ${PORTS[$i]}"
done
echo ""

# Provision each device
NODE_ID=1
for PORT in "${PORTS[@]}"; do
    echo "=== Provisioning Node ${NODE_ID} on ${PORT} ==="

    python3 "${PROVISION_SCRIPT}" \
        --port "${PORT}" \
        --ssid "${WIFI_SSID}" \
        --password "${WIFI_PASS}" \
        --target-ip "${TARGET_IP}" \
        --target-port "${TARGET_PORT}" \
        --node-id "${NODE_ID}"

    echo "Node ${NODE_ID} provisioned."
    echo ""

    NODE_ID=$((NODE_ID + 1))
done

echo "=== Provisioning complete ==="
echo ""
echo "After the ESP32s reboot and connect to WiFi, verify with:"
echo "  ssh root@${TARGET_IP} 'journalctl -u ruview-sensing -f | grep frame'"
