# RuView Sensing System - Deployment Guide

Complete guide for deploying the RuView WiFi sensing system with ESP32 nodes and Orange Pi aggregator.

## Hardware Requirements

| Component | Quantity | Purpose |
|-----------|----------|---------|
| Orange Pi 5 Pro | 1 | Aggregator (sensing-server) |
| ESP32-S3 (8MB flash) | 2-4 | WiFi CSI sensing nodes |
| ESP32-S3 + LD2410C | 0-1 | CSI + 24 GHz radar (distance) |
| ESP32-C6 + MR60BHA2 | 0-1 | 60 GHz radar (vitals) |
| USB chargers (5V) | Per node | Power supply |

## Network Architecture

```
                    ┌─────────────────────────────────┐
                    │      Orange Pi 5 Pro            │
                    │      192.168.x.x:5005 (UDP)     │
                    │      :3022 (HTTP) :3023 (WS)    │
                    └───────────────┬─────────────────┘
                                    │
            ┌───────────┬───────────┼───────────┬───────────┐
            │           │           │           │           │
        ┌───┴───┐   ┌───┴───┐   ┌───┴───┐   ┌───┴───┐
        │Node 1 │   │Node 2 │   │Node 3 │   │Node 7 │
        │ESP32  │   │ESP32  │   │ESP32  │   │ESP32  │
        │ S3    │   │ S3    │   │+LD2410│   │C6+MR60│
        └───────┘   └───────┘   └───────┘   └───────┘
```

## Step 1: Build Firmware

### Prerequisites

- Docker installed
- Python 3.8+
- esptool (`pip install esptool`)

### Build using Docker

```bash
cd firmware/esp32-csi-node

# Clean previous build
docker run --rm -v "$(pwd)":/project -w /project espressif/idf:v5.4 idf.py fullclean

# Build firmware
docker run --rm -v "$(pwd)":/project -w /project espressif/idf:v5.4 idf.py build

# Binaries are in build/
ls -la build/*.bin
```

### Output Files

| File | Offset | Purpose |
|------|--------|---------|
| `bootloader/bootloader.bin` | 0x0 | ESP32 bootloader |
| `partition_table/partition-table.bin` | 0x8000 | Partition layout |
| `ota_data_initial.bin` | 0xf000 | OTA state |
| `esp32-csi-node.bin` | 0x20000 | Main application |

## Step 2: Flash ESP32 Nodes

### Identify Connected Devices

```bash
# macOS
ls /dev/cu.wchusbserial* /dev/cu.usbserial*

# Linux
ls /dev/ttyUSB* /dev/ttyACM*

# Windows
# Use Device Manager to find COM ports
```

### Flash Firmware

```bash
# Using esptool directly
python -m esptool --chip esp32s3 -p /dev/cu.wchusbserial1410 -b 460800 \
  --before default_reset --after hard_reset write_flash \
  --flash_mode dio --flash_size 8MB --flash_freq 80m \
  0x0 build/bootloader/bootloader.bin \
  0x8000 build/partition_table/partition-table.bin \
  0xf000 build/ota_data_initial.bin \
  0x20000 build/esp32-csi-node.bin
```

## Step 3: Provision ESP32 Nodes

Each node needs WiFi credentials, target IP, and a unique Node ID.

### Node ID Assignment

| Node ID | Device | Purpose | Placement |
|---------|--------|---------|-----------|
| 1 | ESP32-S3 | CSI sensing | Corner 1 |
| 2 | ESP32-S3 | CSI sensing | Corner 2 |
| 3 | ESP32-S3 + LD2410C | CSI + radar | Entry/doorway |
| 7 | ESP32-C6 + MR60BHA2 | Vitals radar | Near seating |

### Provision Single Node

```bash
python firmware/esp32-csi-node/provision.py \
  --port /dev/cu.wchusbserial1410 \
  --ssid "YourWiFi" \
  --password "YourPassword" \
  --target-ip 192.168.7.205 \
  --target-port 5005 \
  --node-id 1
```

### Provision All Nodes (Script)

```bash
# Set environment
export WIFI_SSID="YourWiFi"
export WIFI_PASS="YourPassword"
export TARGET_IP="192.168.7.205"

# Run provisioning script
./scripts/provision-esp32-nodes.sh
```

### Identifying Physical Nodes

When nodes are swapped, you can identify them by:

1. **Serial Monitor**: Connect via USB and check boot log
   ```bash
   python -m serial.tools.miniterm /dev/cu.wchusbserial1410 115200
   # Look for: "node_id=X" in output
   ```

2. **Server Logs**: Watch for node connections
   ```bash
   ssh root@192.168.7.205 "journalctl -u ruview-sensing -f | grep node"
   ```

3. **Physical Labeling**: Mark each device with its Node ID after provisioning

## Step 4: Deploy Server to Orange Pi

### Prerequisites

- Rust with `cross` for cross-compilation
- SSH access to Orange Pi

### Cross-Compile

```bash
# Install cross
cargo install cross

# Build for ARM64
cd v2
cross build --release --target aarch64-unknown-linux-gnu -p wifi-densepose-sensing-server
```

### Deploy

```bash
# Copy binary
scp target/aarch64-unknown-linux-gnu/release/sensing-server root@192.168.7.205:/tmp/

# Deploy and restart
ssh root@192.168.7.205 <<'EOF'
systemctl stop ruview-sensing
cp /tmp/sensing-server /root/RuView/v2/target/release/sensing-server
systemctl start ruview-sensing
systemctl status ruview-sensing
EOF
```

### Verify Deployment

```bash
# Check nodes
curl -s http://192.168.7.205:3022/api/v1/nodes | python3 -m json.tool

# Check health
curl -s http://192.168.7.205:3022/health
```

## Step 5: Calibrate the System

### Create Training Recordings

```bash
./scripts/calibrate-sensing.sh 192.168.7.205
```

This creates 4 recordings:
1. `absent` - Empty room (2 min)
2. `present_still` - Person sitting still (2 min)
3. `present_moving` - Person walking slowly (2 min)
4. `active` - Active movement (2 min)

### Train Classifier (Optional)

```bash
curl -X POST http://192.168.7.205:3022/api/v1/adaptive/train
```

### Check Classifier Status

```bash
curl -s http://192.168.7.205:3022/api/v1/adaptive/status
```

## Step 6: Verify Multi-Node Setup

### Check All Nodes Active

```bash
curl -s http://192.168.7.205:3022/api/v1/nodes | jq '.nodes[] | {node_id, status, radar_type}'
```

Expected output:
```json
{"node_id": 1, "status": "active", "radar_type": "none"}
{"node_id": 2, "status": "active", "radar_type": "none"}
{"node_id": 3, "status": "active", "radar_type": "LD2410"}
{"node_id": 7, "status": "active", "radar_type": "MR60BHA2"}
```

### Open Web UI

```
http://192.168.7.205:3022/ui/index.html
```

## Troubleshooting

### Node Not Connecting

1. Check WiFi credentials match
2. Verify target IP is correct
3. Check UDP port 5005 is open on Orange Pi
4. Monitor serial output for errors

### Low Accuracy

1. Re-run calibration with balanced recordings
2. Lower thresholds in csi.rs (already tuned for sensitivity)
3. Add more nodes for spatial diversity
4. Check node placement (avoid co-location)

### Radar Not Detected

1. Check UART wiring (TX/RX to correct pins)
2. Verify radar power supply
3. Monitor serial for "mmWave sensor: LD2410" message

## Files Modified

| File | Change |
|------|--------|
| `firmware/esp32-csi-node/main/edge_processing.h` | Added radar fields |
| `firmware/esp32-csi-node/main/edge_processing.c` | Poll mmwave state |
| `v2/crates/wifi-densepose-sensing-server/src/main.rs` | Parse radar data |

## Quick Reference

```bash
# Build firmware
docker run --rm -v "$(pwd)":/project -w /project espressif/idf:v5.4 idf.py build

# Flash node
python -m esptool --chip esp32s3 -p PORT -b 460800 write_flash @build/flash_args

# Provision node
python provision.py --port PORT --ssid SSID --password PASS --target-ip IP --node-id N

# Deploy server
cross build --release --target aarch64-unknown-linux-gnu -p wifi-densepose-sensing-server
scp target/.../sensing-server root@ORANGEPI:/tmp/
ssh root@ORANGEPI "systemctl stop ruview-sensing && cp /tmp/sensing-server /root/RuView/v2/target/release/ && systemctl start ruview-sensing"

# Check status
curl http://ORANGEPI:3022/api/v1/nodes
```
