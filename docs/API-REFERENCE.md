# RuView Sensing Server API Reference

Base URL: `http://<orange-pi-ip>:3022`

## Health & Status

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Basic health check |
| `/health/live` | GET | Liveness probe |
| `/health/ready` | GET | Readiness probe |
| `/health/version` | GET | Server version info |
| `/health/metrics` | GET | Prometheus-style metrics |

### GET /health

```json
{"status": "ok"}
```

### GET /health/version

```json
{
  "version": "0.3.0",
  "build_timestamp": "2026-05-24T04:09:18Z",
  "git_sha": "abc1234"
}
```

---

## Sensing Data

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/status` | GET | Current sensing status |
| `/api/v1/sensing/latest` | GET | Latest fused sensing data |
| `/api/v1/nodes` | GET | Per-node health and features |
| `/api/v1/vital-signs` | GET | Extracted vital signs |
| `/api/v1/edge-vitals` | GET | Raw ESP32 edge vitals |

### GET /api/v1/nodes

Returns per-node health, motion level, and radar status.

```json
{
  "nodes": [
    {
      "node_id": 1,
      "status": "active",
      "last_seen_ms": 12,
      "rssi_dbm": -65.0,
      "motion_level": "present_moving",
      "person_count": 1,
      "radar_type": "none",
      "radar_present": false,
      "radar_dist_cm": 0
    },
    {
      "node_id": 3,
      "status": "active",
      "last_seen_ms": 8,
      "rssi_dbm": -58.0,
      "motion_level": "present_moving",
      "person_count": 1,
      "radar_type": "LD2410",
      "radar_present": true,
      "radar_dist_cm": 142
    }
  ],
  "total": 4
}
```

### GET /api/v1/sensing/latest

Returns fused sensing data from all nodes.

```json
{
  "timestamp": "2026-05-24T04:15:00Z",
  "presence": true,
  "motion_level": "present_moving",
  "person_count": 2,
  "confidence": 0.85,
  "features": {
    "mean_variance": 0.045,
    "dominant_freq_hz": 0.25,
    "spectral_entropy": 3.2
  }
}
```

### GET /api/v1/vital-signs

Returns smoothed vital sign estimates.

```json
{
  "breathing_rate_bpm": 14.5,
  "heart_rate_bpm": 72.3,
  "breathing_confidence": 0.65,
  "heart_rate_confidence": 0.42,
  "source": "csi_fusion"
}
```

### GET /api/v1/edge-vitals

Returns raw vitals from ESP32 edge processing.

```json
{
  "node_id": 7,
  "presence": true,
  "motion": true,
  "breathing_rate_bpm": 15.2,
  "heartrate_bpm": 68.5,
  "motion_energy": 0.034,
  "presence_score": 0.92,
  "radar_type": 1,
  "radar_present": true,
  "radar_dist_cm": 85
}
```

---

## Pose Estimation

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/pose/current` | GET | Current pose estimates |
| `/api/v1/pose/stats` | GET | Pose statistics |
| `/api/v1/pose/zones/summary` | GET | Zone occupancy summary |

### GET /api/v1/pose/current

```json
{
  "persons": [
    {
      "id": 1,
      "confidence": 0.82,
      "bbox": {"x": 0.2, "y": 0.1, "w": 0.3, "h": 0.6},
      "pose": "standing",
      "position": [1.5, 2.0, 0.0],
      "keypoints": [...]
    }
  ],
  "timestamp_ms": 1779680000
}
```

---

## Recording & Training

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/recording/list` | GET | List all recordings |
| `/api/v1/recording/start` | POST | Start new recording |
| `/api/v1/recording/stop` | POST | Stop current recording |
| `/api/v1/recording/{id}` | DELETE | Delete a recording |

### POST /api/v1/recording/start

Request:
```json
{
  "session_name": "train_absent",
  "label": "absent",
  "duration_secs": 120
}
```

Response:
```json
{
  "status": "recording",
  "session_name": "train_absent_1779680000",
  "label": "absent"
}
```

### GET /api/v1/recording/list

```json
{
  "recordings": [
    {
      "id": "train_absent_1779680000",
      "name": "train_absent_1779680000",
      "label": "absent",
      "frames": 10500,
      "size_bytes": 215000000,
      "status": "completed"
    }
  ]
}
```

---

## Adaptive Classifier

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/adaptive/status` | GET | Classifier status |
| `/api/v1/adaptive/train` | POST | Train from recordings |
| `/api/v1/adaptive/unload` | POST | Unload classifier |

### GET /api/v1/adaptive/status

```json
{
  "loaded": true,
  "training_accuracy": 0.72,
  "training_frames": 45000,
  "labels": ["absent", "present_still", "present_moving", "active"]
}
```

### POST /api/v1/adaptive/train

Trains classifier from recordings with `train_*` prefix.

Response:
```json
{
  "status": "trained",
  "accuracy": 0.72,
  "frames_used": 45000,
  "class_distribution": {
    "absent": 15000,
    "present_still": 10000,
    "present_moving": 10000,
    "active": 10000
  }
}
```

---

## Calibration

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/calibration/start` | POST | Start baseline calibration |
| `/api/v1/calibration/stop` | POST | Stop calibration |
| `/api/v1/calibration/status` | GET | Calibration status |

### POST /api/v1/calibration/start

Start baseline calibration (room should be empty).

```json
{
  "duration_secs": 60
}
```

---

## Models

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/models` | GET | List available models |
| `/api/v1/models/active` | GET | Get active model |
| `/api/v1/models/load` | POST | Load a model |
| `/api/v1/models/unload` | POST | Unload active model |
| `/api/v1/models/{id}` | DELETE | Delete a model |
| `/api/v1/model/info` | GET | Model architecture info |
| `/api/v1/model/sona/profiles` | GET | SONA profiles |
| `/api/v1/model/sona/activate` | POST | Activate SONA profile |

---

## WebSocket Endpoints

| Endpoint | Description |
|----------|-------------|
| `ws://<ip>:3023/ws/sensing` | Real-time sensing data stream |
| `/api/v1/stream/pose` | Pose estimation stream |

### WebSocket: /ws/sensing

Streams JSON frames at ~10 Hz with:

```json
{
  "type": "sensing",
  "timestamp_ms": 1779680000,
  "presence": true,
  "motion_level": "present_moving",
  "person_count": 2,
  "vital_signs": {
    "breathing_rate_bpm": 14.5,
    "heart_rate_bpm": 72.0
  },
  "node_features": [
    {"node_id": 1, "rssi_dbm": -65, "motion_energy": 0.03},
    {"node_id": 3, "rssi_dbm": -58, "motion_energy": 0.04, "radar_dist_cm": 142}
  ]
}
```

---

## Mobile App Integration

The mobile app connects to:

1. **HTTP API** (`http://<ip>:3022/api/v1/...`) for status checks
2. **WebSocket** (`ws://<ip>:3023/ws/sensing`) for real-time updates

### Recommended Mobile Flow

1. `GET /health` - Check server online
2. `GET /api/v1/nodes` - Verify nodes connected
3. Connect to `ws://<ip>:3023/ws/sensing` - Stream data
4. Parse JSON frames for UI updates

### Error Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 400 | Bad request (invalid JSON) |
| 404 | Endpoint not found |
| 500 | Server error |
| 503 | Service unavailable (no data) |

---

## Quick Test Commands

```bash
# Health check
curl http://192.168.7.205:3022/health

# List nodes
curl http://192.168.7.205:3022/api/v1/nodes

# Get vital signs
curl http://192.168.7.205:3022/api/v1/vital-signs

# Start recording
curl -X POST -H "Content-Type: application/json" \
  -d '{"session_name":"test","label":"absent","duration_secs":30}' \
  http://192.168.7.205:3022/api/v1/recording/start

# Train classifier
curl -X POST http://192.168.7.205:3022/api/v1/adaptive/train

# WebSocket test (requires wscat or websocat)
wscat -c ws://192.168.7.205:3023/ws/sensing
```
