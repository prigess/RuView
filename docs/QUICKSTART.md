# RuView WiFi Sensing - Quick Start Guide

Get up and running with RuView WiFi sensing in 30 minutes.

## Overview

RuView uses ESP32 WiFi CSI (Channel State Information) to detect presence, motion, and vital signs without cameras. Optional mmWave radar modules (LD2410C, MR60BHA2) enhance detection accuracy.

## Prerequisites

### Hardware

- **1x Orange Pi 5 Pro** (or any ARM64 Linux SBC)
- **2-4x ESP32-S3** (8MB flash recommended)
- **USB cables** for flashing ESP32s
- **WiFi network** (2.4 GHz)

### Software (Development Machine)

```bash
# Docker (for ESP32 firmware builds)
brew install docker  # macOS
# or: apt install docker.io  # Linux

# Python 3.8+
pip install esptool pyserial

# Rust (for server builds)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install cross
```

## Step 1: Clone Repository

```bash
git clone https://github.com/prigess/RuView.git
cd RuView
```

## Step 2: Build ESP32 Firmware

```bash
cd firmware/esp32-csi-node

# Build using Docker (no ESP-IDF installation needed)
docker run --rm -v "$(pwd)":/project -w /project espressif/idf:v5.4 idf.py fullclean
docker run --rm -v "$(pwd)":/project -w /project espressif/idf:v5.4 idf.py build

# Output: build/esp32-csi-node.bin
```

## Step 3: Flash ESP32 Nodes

Connect each ESP32 via USB and run:

```bash
# Find your serial port
ls /dev/cu.wchusbserial*   # macOS
ls /dev/ttyUSB*            # Linux

# Flash (replace PORT with your device)
python -m esptool --chip esp32s3 -p PORT -b 460800 \
  --before default_reset --after hard_reset write_flash \
  --flash_mode dio --flash_size 8MB --flash_freq 80m \
  0x0 build/bootloader/bootloader.bin \
  0x8000 build/partition_table/partition-table.bin \
  0xf000 build/ota_data_initial.bin \
  0x20000 build/esp32-csi-node.bin
```

## Step 4: Provision ESP32 Nodes

Each node needs WiFi credentials and a unique ID:

```bash
# Node 1
python provision.py --port PORT --ssid "YourWiFi" --password "YourPass" \
  --target-ip 192.168.1.100 --target-port 5005 --node-id 1

# Node 2
python provision.py --port PORT --ssid "YourWiFi" --password "YourPass" \
  --target-ip 192.168.1.100 --target-port 5005 --node-id 2

# Repeat for each node with unique --node-id
```

## Step 5: Build & Deploy Server

On your development machine:

```bash
cd v2

# Cross-compile for ARM64 (Orange Pi)
cross build --release --target aarch64-unknown-linux-gnu \
  -p wifi-densepose-sensing-server

# Copy to Orange Pi
scp target/aarch64-unknown-linux-gnu/release/sensing-server \
  root@192.168.1.100:/opt/ruview/
```

On the Orange Pi:

```bash
# Create systemd service
cat > /etc/systemd/system/ruview.service << 'EOF'
[Unit]
Description=RuView Sensing Server
After=network.target

[Service]
ExecStart=/opt/ruview/sensing-server \
  --bind-addr 0.0.0.0 \
  --source esp32 \
  --udp-port 5005 \
  --http-port 3022 \
  --ws-port 3023 \
  --tick-ms 100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
systemctl daemon-reload
systemctl enable ruview
systemctl start ruview
```

## Step 6: Verify Setup

```bash
# Check server health
curl http://192.168.1.100:3022/health

# Check connected nodes
curl http://192.168.1.100:3022/api/v1/nodes
```

Expected output:
```json
{
  "nodes": [
    {"node_id": 1, "status": "active", "motion_level": "present_moving"},
    {"node_id": 2, "status": "active", "motion_level": "present_still"}
  ],
  "total": 2
}
```

## Step 7: Open Web UI

Navigate to: `http://192.168.1.100:3022/ui/index.html`

## Optional: Add Radar Modules

### LD2410C (24 GHz, presence + distance)

Wire to ESP32-S3:
- VCC → 3.3V
- GND → GND
- TX → GPIO16 (RX)
- RX → GPIO17 (TX)

### MR60BHA2 (60 GHz, vital signs)

Wire to ESP32-C6:
- VCC → 5V
- GND → GND
- TX → GPIO4 (RX)
- RX → GPIO5 (TX)

The firmware auto-detects connected radar modules.

## Calibration (Optional)

For better accuracy, create training recordings:

```bash
./scripts/calibrate-sensing.sh 192.168.1.100
```

Follow prompts to record:
1. Empty room (2 min)
2. Person sitting (2 min)
3. Person walking (2 min)
4. Active movement (2 min)

Then train:
```bash
curl -X POST http://192.168.1.100:3022/api/v1/adaptive/train
```

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check |
| `GET /api/v1/nodes` | Per-node status |
| `GET /api/v1/sensing/latest` | Latest sensing data |
| `GET /api/v1/vital-signs` | Vital sign estimates |
| `WS /ws/sensing` | Real-time data stream |

See [API-REFERENCE.md](API-REFERENCE.md) for complete documentation.

## Troubleshooting

### ESP32 not connecting

1. Check WiFi credentials: `python -m serial.tools.miniterm PORT 115200`
2. Verify target IP matches Orange Pi
3. Ensure UDP port 5005 is open

### No nodes showing in /api/v1/nodes

1. Wait 10-15 seconds for first data
2. Check Orange Pi firewall: `ufw allow 5005/udp`
3. Verify ESP32 is on same network

### Low detection accuracy

1. Spread ESP32s around the room (don't co-locate)
2. Run calibration recordings
3. Lower thresholds in `csi.rs` if needed

## Node Placement

For best results:
```
     Node 1 ─────────────────── Node 2
        │                          │
        │       Room Center        │
        │                          │
     Node 3 ─────────────────── Node 4
```

- Place nodes on opposite walls/corners
- Mount 1-2m high
- Point radar modules toward activity area

## Project Structure

```
RuView/
├── firmware/esp32-csi-node/   # ESP32 firmware (C)
│   ├── main/
│   │   ├── csi_collector.c    # WiFi CSI capture
│   │   ├── edge_processing.c  # On-device signal processing
│   │   ├── mmwave_sensor.c    # LD2410/MR60BHA2 drivers
│   │   └── stream_sender.c    # UDP transmission
│   └── provision.py           # NVS provisioning tool
├── v2/crates/                  # Rust server (workspace)
│   └── wifi-densepose-sensing-server/
│       └── src/main.rs         # HTTP + WebSocket server
├── ui/                         # Web UI
├── scripts/                    # Deployment scripts
└── docs/                       # Documentation
```

## Next Steps

- [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) - Detailed deployment instructions
- [API-REFERENCE.md](API-REFERENCE.md) - Complete API documentation
- [../firmware/esp32-csi-node/README.md](../firmware/esp32-csi-node/README.md) - Firmware details

## Support

- Issues: https://github.com/prigess/RuView/issues
- Documentation: See `docs/` directory
