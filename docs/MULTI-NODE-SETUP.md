# Multi-Node ESP32-S3 Setup Guide

This guide covers setting up a multi-node WiFi sensing deployment with 3+ ESP32-S3 devices.

## Prerequisites

- 3x ESP32-S3 devices (8MB flash recommended, 4MB supported)
- Host machine (Linux, macOS, or Windows with WSL)
- Docker (recommended) or ESP-IDF v5.4 installed
- Rust toolchain (for sensing server)
- Python 3.8+ (for provisioning)

## Quick Start (Automated)

```bash
# 1. Run the setup script
./scripts/setup-multi-node.sh

# 2. Follow the prompts to:
#    - Build firmware
#    - Flash each ESP32-S3
#    - Provision WiFi credentials
#    - Start the sensing server
```

## Manual Setup

### Step 1: Clone the Repository

```bash
git clone https://github.com/prigess/RuView.git
cd RuView
git checkout local-modification
```

### Step 2: Build the Sensing Server

```bash
cd v2
cargo build --release -p wifi-densepose-sensing-server
```

The binary will be at `target/release/sensing-server`.

### Step 3: Build ESP32-S3 Firmware

#### Option A: Docker (Recommended)

```bash
cd firmware/esp32-csi-node
./scripts/build-firmware.sh
```

Or manually:

```bash
docker run --rm -v "$(pwd)":/project -w /project \
  espressif/idf:v5.4 \
  idf.py build
```

#### Option B: Native ESP-IDF

```bash
cd firmware/esp32-csi-node
source /path/to/esp-idf/export.sh
idf.py build
```

### Step 4: Identify Your ESP32-S3 Devices

Run the identification script to find which port corresponds to which physical device:

```bash
./scripts/identify-esp32-nodes.sh
```

This will blink LEDs and display serial output to help you identify each device.

### Step 5: Flash Each Device

```bash
# Flash device on port /dev/ttyUSB0 (adjust port as needed)
./scripts/flash-node.sh /dev/ttyUSB0

# Repeat for each device
./scripts/flash-node.sh /dev/ttyUSB1
./scripts/flash-node.sh /dev/ttyUSB2
```

### Step 6: Provision WiFi Credentials

Each node needs to know:
- Your WiFi SSID and password
- The IP address of your sensing server

```bash
# Provision first node
./scripts/provision-node.sh /dev/ttyUSB0 "YourWiFi" "YourPassword" 192.168.1.100

# Repeat for each device
./scripts/provision-node.sh /dev/ttyUSB1 "YourWiFi" "YourPassword" 192.168.1.100
./scripts/provision-node.sh /dev/ttyUSB2 "YourWiFi" "YourPassword" 192.168.1.100
```

### Step 7: Start the Sensing Server

```bash
./scripts/start-server.sh
```

Or manually:

```bash
cd v2
cargo run --release -p wifi-densepose-sensing-server -- \
  --bind-addr 0.0.0.0 \
  --source esp32 \
  --http-port 8080 \
  --udp-port 5005
```

### Step 8: Open the UI

Navigate to: `http://<HOST_IP>:8080`

## Verification

### Check Nodes Are Connected

```bash
curl http://localhost:8080/api/v1/nodes | jq
```

Expected output:
```json
{
  "nodes": [
    {"node_id": 1, "rssi": -45, "last_seen_ms": 100},
    {"node_id": 2, "rssi": -52, "last_seen_ms": 150},
    {"node_id": 3, "rssi": -48, "last_seen_ms": 120}
  ]
}
```

### Monitor Real-Time Data

```bash
# WebSocket stream
websocat ws://localhost:8765/ws/sensing
```

### Check Server Logs

```bash
# If running via script
tail -f /tmp/sensing-server.log
```

## Troubleshooting

### Node Not Appearing

1. Check WiFi credentials are correct
2. Verify target IP matches server's IP
3. Check firewall allows UDP port 5005
4. Monitor serial output: `python -m serial.tools.miniterm /dev/ttyUSB0 115200`

### Poor Detection Accuracy

1. Ensure nodes are positioned 2-5 meters apart
2. Avoid placing nodes behind metal objects
3. Run field calibration: `curl -X POST http://localhost:8080/api/v1/calibrate`

### Frame Parsing Errors

If you see type mismatch errors, ensure you're using the `local-modification` branch which has the corrected frame parser.

## Network Architecture

```
                    ┌─────────────────┐
                    │  Sensing Server │
                    │  (UDP :5005)    │
                    │  (HTTP :8080)   │
                    │  (WS :8765)     │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ ESP32-S3 │  │ ESP32-S3 │  │ ESP32-S3 │
        │ Node 1   │  │ Node 2   │  │ Node 3   │
        └──────────┘  └──────────┘  └──────────┘
```

## Detection Thresholds

The current build uses these thresholds for presence classification:

| Level | Score Threshold | Description |
|-------|-----------------|-------------|
| Active | > 0.20 | Significant movement detected |
| Present (Moving) | > 0.08 | Light movement or walking |
| Present (Still) | > 0.025 | Stationary person detected |
| Absent | ≤ 0.025 | No presence detected |

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/nodes` | GET | List connected nodes |
| `/api/v1/status` | GET | Server status |
| `/api/v1/calibrate` | POST | Start field calibration |
| `/api/v1/config` | GET/POST | Get/set configuration |
| `/ws/sensing` | WS | Real-time sensing stream |

## Support

- Issues: https://github.com/ruvnet/RuView/issues
- Documentation: https://github.com/ruvnet/RuView/docs
