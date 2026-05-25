# RuView Demo Improvements — 1 Week Sprint

> **Goal:** Dazzle customers with accurate person counting, multi-ESP32 dome, and reliable sensing.

---

## Current State

| Metric | Current | Target |
|--------|---------|--------|
| Person count accuracy | ~40% | >85% |
| Classifier accuracy | 41.5% | >80% |
| ESP32 nodes | 1 | 4 (dome) |
| FieldModel calibration | None | Calibrated |
| Training recordings | 0 labeled | 4+ labeled |

---

## Phase 1: Quick Wins (Days 1-2)

### 1.1 Create Labeled Training Recordings

Record 2-minute sessions for each class using the sensing server's recording API:

```bash
# On the Orange Pi or via API
curl -X POST http://192.168.7.205:3022/api/recording/start?label=absent
# Wait 2 min with empty room
curl -X POST http://192.168.7.205:3022/api/recording/stop

curl -X POST http://192.168.7.205:3022/api/recording/start?label=present_still
# Wait 2 min with 1 person sitting still
curl -X POST http://192.168.7.205:3022/api/recording/stop

curl -X POST http://192.168.7.205:3022/api/recording/start?label=present_moving
# Wait 2 min with 1 person walking around
curl -X POST http://192.168.7.205:3022/api/recording/stop

curl -X POST http://192.168.7.205:3022/api/recording/start?label=active
# Wait 2 min with 1-2 people moving actively
curl -X POST http://192.168.7.205:3022/api/recording/stop
```

**Naming convention:** Recording API should save as `train_<label>_<timestamp>.jsonl`

### 1.2 Calibrate FieldModel (Empty Room Baseline)

```bash
# Start calibration with empty room
curl -X POST http://192.168.7.205:3022/api/calibration/start

# Wait 60 seconds with empty room
sleep 60

# Stop calibration — model will compute SVD baseline
curl -X POST http://192.168.7.205:3022/api/calibration/stop
```

### 1.3 Retrain Adaptive Classifier

```bash
# After recordings are saved with train_* prefix
curl -X POST http://192.168.7.205:3022/api/train
```

### 1.4 Tune Thresholds

Current thresholds in `score_to_person_count()`:
- 0.70 → 2 people
- 0.85 → 3 people

For most rooms, these are too high. Lower to:
- 0.55 → 2 people
- 0.75 → 3 people

---

## Phase 2: Multi-ESP32 Dome (Days 3-5)

### 2.1 Hardware Setup

Position 4 ESP32-S3 nodes in a dome/perimeter arrangement:

```
        [ESP32-2]
           N
           |
  [ESP32-1]---[ESP32-3]
     W    |    E
           |
        [ESP32-4]
           S
```

**Recommended positions (3m x 3m room, z=1.5m height):**
```json
{
  "nodes": [
    {"id": 1, "ip": "192.168.7.101", "position": [0.0, 1.5, 1.5]},
    {"id": 2, "ip": "192.168.7.102", "position": [1.5, 3.0, 1.5]},
    {"id": 3, "ip": "192.168.7.103", "position": [3.0, 1.5, 1.5]},
    {"id": 4, "ip": "192.168.7.104", "position": [1.5, 0.0, 1.5]}
  ]
}
```

### 2.2 Flash and Provision ESP32 Nodes

```bash
# For each ESP32:
python firmware/esp32-csi-node/provision.py \
  --port /dev/ttyUSBx \
  --ssid "YourWiFi" \
  --password "secret" \
  --target-ip 192.168.7.205
```

### 2.3 Create Node IP Map

Create `/root/RuView/data/esp32-node-ip-map.json`:

```json
{
  "1": {"ip": "192.168.7.101", "name": "west", "position": [0.0, 1.5, 1.5]},
  "2": {"ip": "192.168.7.102", "name": "north", "position": [1.5, 3.0, 1.5]},
  "3": {"ip": "192.168.7.103", "name": "east", "position": [3.0, 1.5, 1.5]},
  "4": {"ip": "192.168.7.104", "name": "south", "position": [1.5, 0.0, 1.5]}
}
```

### 2.4 Configure Server for Multi-Node

```bash
# Restart sensing server with node positions
systemctl stop ruview-sensing
/root/RuView/v2/target/release/sensing-server \
  --bind-addr 0.0.0.0 \
  --source esp32 \
  --node-positions "0,1.5,1.5;1.5,3,1.5;3,1.5,1.5;1.5,0,1.5"
```

---

## Phase 3: Accuracy Tuning (Days 5-7)

### 3.1 Adjust Person Count Thresholds

Edit `v2/crates/wifi-densepose-sensing-server/src/csi.rs`:

```rust
pub fn score_to_person_count(smoothed_score: f64, prev_count: usize) -> usize {
    match prev_count {
        0 | 1 => {
            if smoothed_score > 0.75 { 3 }      // was 0.85
            else if smoothed_score > 0.55 { 2 } // was 0.70
            else { 1 }
        }
        2 => {
            if smoothed_score > 0.85 { 3 }      // was 0.92
            else if smoothed_score < 0.45 { 1 } // was 0.55
            else { 2 }
        }
        _ => {
            if smoothed_score < 0.45 { 1 }      // was 0.55
            else if smoothed_score < 0.65 { 2 } // was 0.78
            else { 3 }
        }
    }
}
```

### 3.2 Adjust FieldModel Energy Thresholds

Edit `v2/crates/wifi-densepose-sensing-server/src/field_bridge.rs`:

```rust
// Lower thresholds for more sensitive detection
const ENERGY_THRESH_2: f64 = 8.0;  // was 12.0
const ENERGY_THRESH_3: f64 = 18.0; // was 25.0
```

### 3.3 Rebuild and Deploy

```bash
# On Mac (cross-compile for aarch64)
cd v2
cross build --release --target aarch64-unknown-linux-gnu -p wifi-densepose-sensing-server

# Copy to device
scp target/aarch64-unknown-linux-gnu/release/sensing-server root@192.168.7.205:/root/RuView/v2/target/release/

# Restart
ssh root@192.168.7.205 "systemctl restart ruview-sensing"
```

---

## Phase 4: Demo Polish (Day 7)

### 4.1 UI Improvements

- Enable smooth skeleton rendering
- Add person count badge overlay
- Show node status indicators
- Display vital signs panel

### 4.2 Demo Script

1. Start with empty room — show "0 people" detection
2. One person enters — count updates to 1, skeleton appears
3. Second person enters — count updates to 2, both tracked
4. Walking demo — show smooth tracking
5. Vital signs — show breathing rate for stationary person

### 4.3 Fallback Plan

If multi-ESP32 isn't ready:
- Single ESP32 with tuned thresholds can still demo 1-2 person counting
- Focus on presence/absence accuracy
- Show vital signs feature prominently

---

## Quick Reference

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/status` | GET | Server status, node count |
| `/api/recording/start?label=X` | POST | Start labeled recording |
| `/api/recording/stop` | POST | Stop recording |
| `/api/train` | POST | Retrain classifier |
| `/api/calibration/start` | POST | Start FieldModel calibration |
| `/api/calibration/stop` | POST | Stop calibration |

### Key Files

| File | Purpose |
|------|---------|
| `csi.rs:629` | `score_to_person_count()` thresholds |
| `field_bridge.rs:18-20` | Energy thresholds for occupancy |
| `adaptive_classifier.rs` | Classifier training logic |
| `data/adaptive_model.json` | Trained model (on device) |
| `data/esp32-node-ip-map.json` | Node IP mapping |

### Build Commands

```bash
# Cross-compile on Mac
cd v2
cargo build --release --target aarch64-unknown-linux-gnu -p wifi-densepose-sensing-server

# Native build on Orange Pi
cargo build --release -p wifi-densepose-sensing-server
```
