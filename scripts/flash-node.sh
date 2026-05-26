#!/bin/bash
# Flash ESP32-S3 firmware to a specific port

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="$(cd "$SCRIPT_DIR/../firmware/esp32-csi-node" && pwd)"

PORT="${1:-/dev/ttyUSB0}"
BAUD="${2:-460800}"

if [ ! -e "$PORT" ]; then
    echo "Error: Port $PORT not found!"
    echo ""
    echo "Available ports:"
    ls /dev/ttyUSB* /dev/ttyACM* /dev/cu.usbserial* /dev/cu.SLAB* 2>/dev/null || echo "  No USB serial ports found"
    exit 1
fi

# Check if firmware is built
if [ ! -f "$FIRMWARE_DIR/build/esp32-csi-node.bin" ]; then
    echo "Error: Firmware not built!"
    echo "Run: ./scripts/build-firmware.sh"
    exit 1
fi

echo "Flashing ESP32-S3 on $PORT..."
echo ""

cd "$FIRMWARE_DIR"

# Flash with Docker or native
if command -v docker &> /dev/null; then
    # Note: Docker needs device access, which may require --privileged on Linux
    docker run --rm \
        -v "$(pwd)":/project \
        -w /project \
        --device="$PORT" \
        espressif/idf:v5.4 \
        idf.py -p "$PORT" -b "$BAUD" flash

elif command -v idf.py &> /dev/null; then
    idf.py -p "$PORT" -b "$BAUD" flash

elif command -v esptool.py &> /dev/null; then
    # Fallback to esptool directly
    esptool.py --chip esp32s3 -p "$PORT" -b "$BAUD" \
        --before default_reset --after hard_reset \
        write_flash --flash_mode dio --flash_freq 80m --flash_size 8MB \
        0x0 build/bootloader/bootloader.bin \
        0x8000 build/partition_table/partition-table.bin \
        0x10000 build/esp32-csi-node.bin

else
    echo "Error: No flashing tool found!"
    echo "Install esptool: pip install esptool"
    exit 1
fi

echo ""
echo "Flash complete!"
echo ""
echo "Next: Provision WiFi credentials"
echo "  ./scripts/provision-node.sh $PORT \"SSID\" \"password\" server_ip"
