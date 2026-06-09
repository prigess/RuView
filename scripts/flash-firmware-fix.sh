#!/usr/bin/env bash
# Flash the rate-limit firmware fix to all 3 dome ESP32-S3 nodes in parallel.
#
# What this flashes:
#   - csi_collector.c  CSI_MIN_SEND_INTERVAL_US: 20ms (50Hz) → 100ms (10Hz)
#                      sendto failure log changed from first-5 to every-100th
#   - stream_sender.c  ENOMEM_COOLDOWN_MS: 100ms → 300ms
#
# Uses `idf.py app-flash` so NVS is preserved — SSID, target_ip, node_id all
# survive the flash. Just runs the app partition update on each port.
#
# Prereq: ESP-IDF v5.4 toolchain set up; firmware/.../build/ contains the
# fresh post-fix binaries (this script does NOT rebuild — run `idf.py build`
# first if needed).
#
# Usage:
#   . ~/esp/esp-idf/export.sh        # set up IDF_PATH for this shell
#   ./scripts/flash-firmware-fix.sh

set -euo pipefail

FW_DIR="/Users/anandvayyala/Ru/RuView/firmware/esp32-csi-node"
BUILD_DIR="$FW_DIR/build"

PORT_A="/dev/cu.wchusbserial5B7A0773891"   # Node 1 — West
PORT_B="/dev/cu.wchusbserial5B7B0511421"   # Node 2 — North
PORT_C="/dev/cu.wchusbserial5B7B0519241"   # Node 3 — East

# ── prereq checks ────────────────────────────────────────────────────────────
if [ -z "${IDF_PATH:-}" ]; then
    echo "ERROR: ESP-IDF not in this shell. Run:" >&2
    echo "  . ~/esp/esp-idf/export.sh" >&2
    exit 1
fi
command -v idf.py >/dev/null || { echo "ERROR: idf.py not found in PATH" >&2; exit 1; }
[ -f "$BUILD_DIR/esp32-csi-node.bin" ] || {
    echo "ERROR: $BUILD_DIR/esp32-csi-node.bin not found." >&2
    echo "Build first:  (cd $FW_DIR && idf.py set-target esp32s3 && idf.py build)" >&2
    exit 1
}

# Confirm the build is newer than the source change (sanity check).
SRC_TIME=$(stat -f %m "$FW_DIR/main/csi_collector.c" 2>/dev/null || echo 0)
BIN_TIME=$(stat -f %m "$BUILD_DIR/esp32-csi-node.bin" 2>/dev/null || echo 0)
if [ "$BIN_TIME" -lt "$SRC_TIME" ]; then
    echo "WARNING: build artifact is older than csi_collector.c source." >&2
    echo "  bin:   $(date -r "$BIN_TIME" '+%Y-%m-%d %H:%M:%S')" >&2
    echo "  src:   $(date -r "$SRC_TIME" '+%Y-%m-%d %H:%M:%S')" >&2
    echo "Rebuild before flashing:  (cd $FW_DIR && idf.py build)" >&2
    read -r -p "Continue anyway? [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
fi

# ── flash each port (sequential to avoid esptool stomp on each other) ────────
flash_one() {
    local port="$1" name="$2"
    if [ ! -e "$port" ]; then
        echo "  $name ($port): NOT ATTACHED — skipping"
        return 1
    fi
    echo ""
    echo "════════════════════════════════════════════════"
    echo "  Flashing $name on $port"
    echo "════════════════════════════════════════════════"
    (cd "$FW_DIR" && idf.py -p "$port" app-flash) || {
        echo "  $name: FLASH FAILED" >&2
        return 1
    }
    echo "  $name: ✓ flashed"
}

flash_one "$PORT_A" "Node 1 (West)"  || true
flash_one "$PORT_B" "Node 2 (North)" || true
flash_one "$PORT_C" "Node 3 (East)"  || true

# ── verify: hard reset all + check Pi after 12 s ─────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  Resetting all nodes and verifying at the Pi"
echo "════════════════════════════════════════════════"
for port in "$PORT_A" "$PORT_B" "$PORT_C"; do
    [ -e "$port" ] || continue
    python3 -m esptool --port "$port" --baud 115200 \
        --before default_reset --after hard_reset chip_id 2>&1 \
        | grep -E "Hard reset|MAC" | tail -2 &
done
wait
echo ""
echo "Waiting 15s for boot + WiFi + first frames..."
sleep 15
echo ""
curl -s http://192.168.7.205:3022/api/v1/nodes | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Pi sees {d[\"total\"]} nodes:')
for n in d['nodes']:
    fresh = '✓ active' if n['last_seen_ms'] < 2000 else '✗ stale '
    print(f\"  {fresh}  node_id={n['node_id']}  last_seen={n['last_seen_ms']:>5}ms  rssi={n['rssi_dbm']:>6} dBm\")
"

echo ""
echo "Confirm sustained streaming with:  curl -s http://192.168.7.205:3022/api/v1/nodes | jq"
