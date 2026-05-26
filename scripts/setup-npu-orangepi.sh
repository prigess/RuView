#!/bin/bash
# Setup RK3588 NPU for RuView on Orange Pi 5 Pro
# Run as root on the Orange Pi

set -e

echo "=============================================="
echo "  RuView NPU Setup for Orange Pi 5 Pro"
echo "=============================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "ERROR: This script is for aarch64 (ARM64) only"
    echo "Current architecture: $ARCH"
    exit 1
fi

echo ""
echo "=== Step 1: Create NPU device node ==="
if [ ! -c /dev/rknpu0 ]; then
    # RK3588 NPU registers as misc device 126
    mknod /dev/rknpu0 c 10 126 2>/dev/null || true
    chmod 666 /dev/rknpu0
    echo "Created /dev/rknpu0"
else
    echo "/dev/rknpu0 already exists"
fi

echo ""
echo "=== Step 2: Create udev rule for persistence ==="
cat > /etc/udev/rules.d/99-rknpu.rules << 'UDEV'
# RK3588 NPU device node - created by RuView setup
KERNEL=="rknpu", SUBSYSTEM=="misc", MODE="0666"
SUBSYSTEM=="misc", ATTR{name}=="rknpu", MODE="0666", SYMLINK+="rknpu0"
UDEV
udevadm control --reload-rules
echo "Udev rules installed"

echo ""
echo "=== Step 3: Check/Install librknnrt.so ==="
if [ ! -f /usr/lib/librknnrt.so ]; then
    echo "Downloading librknnrt.so..."
    cd /tmp
    wget -q "https://github.com/airockchip/rknn-toolkit2/raw/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so" -O librknnrt.so
    cp librknnrt.so /usr/lib/
    ldconfig
    echo "Installed librknnrt.so"
else
    echo "librknnrt.so already installed"
fi

echo ""
echo "=== Step 4: Install RKNN Python toolkit ==="
pip3 install --quiet rknn-toolkit-lite2 2>/dev/null || {
    echo "Installing from PyPI..."
    pip3 install rknn-toolkit-lite2
}
echo "rknn-toolkit-lite2 installed"

echo ""
echo "=== Step 5: Create NPU init script ==="
cat > /usr/local/bin/init-npu.sh << 'SCRIPT'
#!/bin/bash
# Initialize RK3588 NPU - called by ruview-sensing.service
if [ ! -c /dev/rknpu0 ]; then
    mknod /dev/rknpu0 c 10 126 2>/dev/null || true
    chmod 666 /dev/rknpu0
fi
[ -c /dev/rknpu0 ] && echo "[NPU] Ready" || { echo "[NPU] Failed"; exit 1; }
SCRIPT
chmod +x /usr/local/bin/init-npu.sh
echo "Init script created"

echo ""
echo "=== Step 6: Update ruview-sensing.service ==="
if [ -f /etc/systemd/system/ruview-sensing.service ]; then
    # Check if ExecStartPre already has NPU init
    if ! grep -q "init-npu.sh" /etc/systemd/system/ruview-sensing.service; then
        # Add NPU init as prerequisite
        sed -i '/\[Service\]/a ExecStartPre=/usr/local/bin/init-npu.sh' /etc/systemd/system/ruview-sensing.service
        sed -i '/\[Service\]/a Environment=RUVIEW_USE_NPU=1' /etc/systemd/system/ruview-sensing.service
        systemctl daemon-reload
        echo "Service updated with NPU prerequisite"
    else
        echo "Service already has NPU prerequisite"
    fi
else
    echo "ruview-sensing.service not found - will be created on install"
fi

echo ""
echo "=== Step 7: Verify NPU ==="
python3 << 'PYTEST'
from rknnlite.api import RKNNLite
import os

errors = []

# Test device
try:
    fd = os.open("/dev/rknpu0", os.O_RDWR)
    os.close(fd)
    print("✓ /dev/rknpu0 accessible")
except Exception as e:
    errors.append(f"Device: {e}")
    print(f"✗ /dev/rknpu0: {e}")

# Test library
try:
    rknn = RKNNLite(verbose=False)
    print("✓ RKNN runtime loaded")
    rknn.release()
except Exception as e:
    errors.append(f"Runtime: {e}")
    print(f"✗ RKNN runtime: {e}")

if errors:
    print("\nWARNING: Some tests failed")
    exit(1)
else:
    print("\n✓ NPU is ready for RuView!")
PYTEST

echo ""
echo "=============================================="
echo "  NPU Setup Complete!"
echo "=============================================="
echo ""
echo "NPU Status:"
echo "  Device: /dev/rknpu0"
echo "  Library: /usr/lib/librknnrt.so"
echo "  Python: rknn-toolkit-lite2"
echo ""
echo "To use NPU acceleration:"
echo "  1. Convert models to .rknn format"
echo "  2. Set RUVIEW_USE_NPU=1"
echo "  3. Restart: systemctl restart ruview-sensing"
echo ""
echo "Monitor NPU load:"
echo "  cat /sys/kernel/debug/rknpu/load"
