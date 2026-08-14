#!/usr/bin/env bash
# Re-provision the south-dome ESP32-S3 (currently node_id=7, MAC 58:e6:c5:19:a4:40)
# to node_id=4 so it lines up with the "south" position in
# /root/RuView/data/esp32-node-ip-map.json on the Pi.
#
# WHEN TO RUN: next time you take the dome's south-position node off the wall
# and plug its USB cable into this Mac.
#
# WHAT IT DOES: rewrites the `csi_cfg` NVS namespace via firmware/esp32-csi-node/provision.py
# (merges with existing values — keeps SSID/password as they are).
#
# USAGE:
#   ./scripts/reprovision-node7-to-node4.sh                       # auto-detect port
#   ./scripts/reprovision-node7-to-node4.sh /dev/cu.wchusbserial...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── pick a serial port ───────────────────────────────────────────────────────
PORT="${1:-}"
if [ -z "$PORT" ]; then
    mapfile -t PORTS < <(ls /dev/cu.wchusbserial* /dev/cu.usbmodem* 2>/dev/null || true)
    if [ "${#PORTS[@]}" -eq 0 ]; then
        echo "No USB serial ports found. Plug Node 7 in via USB, then re-run."
        exit 1
    fi
    if [ "${#PORTS[@]}" -eq 1 ]; then
        PORT="${PORTS[0]}"
    else
        echo "Multiple ports found — specify which one explicitly:"
        printf '  %s\n' "${PORTS[@]}"
        echo "Usage: $0 <port>"
        exit 1
    fi
fi

echo "=== Re-provision Node 7 → Node 4 ==="
echo "Port      : $PORT"
echo ""

# ── confirm we're talking to Node 7 (MAC check) ──────────────────────────────
EXPECTED_MAC="58:e6:c5:19:a4:40"
echo "[1/4] verifying MAC ($EXPECTED_MAC expected)..."
MAC=$(python3 -m esptool --port "$PORT" --baud 115200 --before default_reset --after no_reset chip_id 2>&1 \
        | grep -oE "[0-9a-f]{2}(:[0-9a-f]{2}){5}" | head -1)
if [ -z "$MAC" ]; then
    echo "ERROR: could not read MAC from $PORT."
    exit 1
fi
echo "  read MAC: $MAC"
if [ "$MAC" != "$EXPECTED_MAC" ]; then
    echo ""
    echo "  WARNING: the device on $PORT has MAC $MAC, not the expected $EXPECTED_MAC."
    echo "  This may not be the south-dome Node 7. Continue anyway? [y/N]"
    read -r CONFIRM
    [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "aborted."; exit 1; }
fi

# ── grab credentials from local inventory (so we don't have to re-type) ──────
echo ""
echo "[2/4] re-provisioning csi_cfg NVS namespace..."
read -r -s -p "WiFi password for 'Firefly' (press Enter to leave NVS password unchanged): " PASSWORD
echo ""

ARGS=(
    "${REPO_ROOT}/firmware/esp32-csi-node/provision.py"
    --port "$PORT"
    --chip esp32c6
    --ssid Firefly
    --target-ip 192.168.7.205
    --target-port 5005
    --node-id 4
)
if [ -n "${PASSWORD}" ]; then
    ARGS+=( --password "$PASSWORD" )
fi

python3 "${ARGS[@]}"

# ── verify by watching boot ──────────────────────────────────────────────────
echo ""
echo "[3/4] resetting + watching boot for 20 seconds..."
python3 -m esptool --port "$PORT" --baud 115200 --before default_reset --after hard_reset chip_id 2>&1 | tail -2
python3 - <<PY
import serial, time, re
s = serial.Serial("$PORT", 115200, timeout=0.3)
s.reset_input_buffer()
end = time.time() + 20
patterns = re.compile(r'(got ip|stream_sender|csi_collector: CSI collection|main: CSI streaming)', re.IGNORECASE)
for line in iter(lambda: s.readline().decode('utf-8', errors='replace').rstrip(), None):
    if not line and time.time() >= end: break
    clean = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
    if patterns.search(clean):
        print("  " + clean)
    if "CSI streaming active" in clean:
        break
s.close()
PY

# ── flip the map on the Pi ───────────────────────────────────────────────────
echo ""
echo "[4/4] enabling node_id=4 in /root/RuView/data/esp32-node-ip-map.json on the Pi..."
ssh root@192.168.7.205 'python3 -c "
import json, pathlib
p = pathlib.Path(\"/root/RuView/data/esp32-node-ip-map.json\")
d = json.loads(p.read_text())
for n in d[\"nodes\"]:
    if n[\"id\"] == 4:
        n[\"enabled\"] = True
        n.pop(\"_pending\", None)
p.write_text(json.dumps(d, indent=2))
print(\"  ip-map updated\")
"; systemctl restart ruview-sensing && echo "  sensing-server restarted"' 2>&1

echo ""
echo "✓ Done. Verify with:"
echo "    curl -s http://192.168.7.205:3022/api/v1/nodes | jq '.nodes[] | select(.node_id == 4)'"
