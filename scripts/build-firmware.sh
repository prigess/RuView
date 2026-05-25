#!/bin/bash
# Build ESP32-S3 CSI firmware using Docker or native ESP-IDF

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="$(cd "$SCRIPT_DIR/../firmware/esp32-csi-node" && pwd)"

# Parse arguments
FLASH_SIZE="${1:-8MB}"  # 8MB or 4MB

echo "Building ESP32-S3 CSI firmware ($FLASH_SIZE flash)..."

cd "$FIRMWARE_DIR"

# Select sdkconfig based on flash size
if [ "$FLASH_SIZE" = "4MB" ]; then
    if [ -f "sdkconfig.defaults.4mb" ]; then
        cp sdkconfig.defaults.4mb sdkconfig.defaults
        echo "Using 4MB flash configuration"
    else
        echo "Warning: sdkconfig.defaults.4mb not found, using default"
    fi
fi

# Clean previous build
rm -rf build sdkconfig 2>/dev/null || true

# Build with Docker or native ESP-IDF
if command -v docker &> /dev/null; then
    echo "Building with Docker ESP-IDF v5.4..."
    docker run --rm \
        -v "$(pwd)":/project \
        -w /project \
        espressif/idf:v5.4 \
        idf.py build

elif command -v idf.py &> /dev/null; then
    echo "Building with native ESP-IDF..."
    idf.py build

else
    echo "Error: Neither Docker nor ESP-IDF found!"
    echo ""
    echo "Install Docker:"
    echo "  https://docs.docker.com/get-docker/"
    echo ""
    echo "Or install ESP-IDF v5.4:"
    echo "  https://docs.espressif.com/projects/esp-idf/en/v5.4/esp32s3/get-started/"
    exit 1
fi

echo ""
echo "Build complete!"
echo "Firmware binary: $FIRMWARE_DIR/build/esp32-csi-node.bin"
echo ""
echo "To flash: ./scripts/flash-node.sh /dev/ttyUSB0"
