# RuView Sensing Server — API Reference

> For mobile app developers. All examples use real responses captured from the live Orange Pi device with 4 ESP32 nodes.

**Base URL:** `http://<device-ip>:3022`  
**Default port:** `3022` (the Orange Pi runs on this port)  
**Auth:** Bearer token — optional. Set `RUVIEW_API_TOKEN=<token>` on the server to enforce it. When enabled, include `Authorization: Bearer <token>` on all `/api/v1/*` requests. Health endpoints and the UI are never gated.  
**Response format:** JSON on all endpoints (except `/api/v1/mesh/metrics` which returns Prometheus text format)  
**Cache:** All responses include `Cache-Control: no-cache, no-store, must-revalidate`

---

## Table of Contents

1. [Health & System](#1-health--system)
2. [Info & Metrics](#2-info--metrics)
3. [Sensing Data](#3-sensing-data)
4. [Pose Estimation](#4-pose-estimation)
5. [Vital Signs](#5-vital-signs)
6. [Nodes & Mesh](#6-nodes--mesh)
7. [Models](#7-models)
8. [Recording](#8-recording)
9. [Training](#9-training)
10. [Adaptive Classifier](#10-adaptive-classifier)
11. [Calibration](#11-calibration)
12. [Configuration](#12-configuration)
13. [Edge & WASM](#13-edge--wasm)
14. [Introspection](#14-introspection)
15. [WebSockets](#15-websockets)
16. [Error Handling](#16-error-handling)

---

## 1. Health & System

### `GET /health`

Basic health check. Use this for polling server availability.

**Response**
```json
{
  "clients": 0,
  "source": "esp32",
  "status": "ok",
  "tick": 997606
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Always `"ok"` when server is running |
| `source` | string | Data source: `"esp32"` (real hardware), `"simulate"`, `"file"` |
| `clients` | int | Active WebSocket clients |
| `tick` | int | Increments every 100ms — use to detect stale connections |

---

### `GET /health/health`

Detailed component health breakdown.

**Response**
```json
{
  "status": "healthy",
  "components": {
    "api":      { "status": "healthy", "message": "Rust Axum server" },
    "hardware": { "status": "healthy", "message": "Source: esp32" },
    "pose":     { "status": "healthy", "message": "WiFi-derived pose estimation" },
    "stream":   { "status": "idle",    "message": "0 client(s)" }
  },
  "metrics": {
    "uptime_seconds": 10660,
    "cpu_percent": 2.5,
    "memory_percent": 1.8,
    "disk_percent": 15.0
  }
}
```

---

### `GET /health/live`

Kubernetes-style liveness probe.

**Response**
```json
{ "status": "alive", "uptime": 10660 }
```

---

### `GET /health/ready`

Readiness probe — confirms the server is serving sensing data.

**Response**
```json
{ "status": "ready", "source": "esp32" }
```

---

### `GET /health/version`

Server version information.

**Response**
```json
{
  "name": "wifi-densepose-sensing-server",
  "version": "0.3.0",
  "backend": "rust+axum+ruvector"
}
```

---

### `GET /health/metrics`

System resource metrics.

**Response**
```json
{
  "tick": 997618,
  "system_metrics": {
    "cpu":    { "percent": 2.5 },
    "memory": { "percent": 1.8, "used_mb": 5 },
    "disk":   { "percent": 15.0 }
  }
}
```

---

## 2. Info & Metrics

### `GET /api/v1/info`

Server capabilities and runtime configuration.

**Response**
```json
{
  "version": "0.3.0",
  "backend": "rust",
  "environment": "production",
  "source": "esp32",
  "features": {
    "wifi_sensing": true,
    "pose_estimation": true,
    "signal_processing": true,
    "ruvector": true,
    "streaming": true
  }
}
```

---

### `GET /api/v1/status`

Alias for `/health/ready`.

**Response**
```json
{ "status": "ready", "source": "esp32" }
```

---

### `GET /api/v1/metrics`

Alias for `/health/metrics`.

---

## 3. Sensing Data

### `GET /api/v1/sensing/latest`

Full fused sensing snapshot. This is the richest single endpoint — includes per-node CSI, person list, vitals, and signal field.

**Response** (abbreviated)
```json
{
  "source": "esp32",
  "tick": 998281,
  "timestamp": 1780112413.134,
  "type": "sensing_update",

  "estimated_persons": 5,

  "classification": {
    "presence": true,
    "motion_level": "present_moving",
    "confidence": 0.514
  },

  "features": {
    "mean_rssi": -73.0,
    "variance": 197.97,
    "dominant_freq_hz": 3.85,
    "spectral_power": 381.79,
    "motion_band_power": 109.03,
    "breathing_band_power": 157.68,
    "change_points": 11
  },

  "node_features": [
    {
      "node_id": 2,
      "rssi_dbm": -81.0,
      "last_seen_ms": 8,
      "stale": false,
      "frame_rate_hz": 0.0,
      "novelty_score": 0.0,
      "classification": {
        "presence": true,
        "motion_level": "present_moving",
        "confidence": 0.333
      },
      "features": {
        "mean_rssi": -81.0,
        "variance": 177.75,
        "dominant_freq_hz": 4.05,
        "spectral_power": 337.10,
        "motion_band_power": 134.52,
        "breathing_band_power": 147.83,
        "change_points": 3
      }
    }
  ],

  "nodes": [
    {
      "node_id": 2,
      "rssi_dbm": -81.0,
      "subcarrier_count": 128,
      "position": [2.0, 0.0, 1.5],
      "amplitude": [0.0, 12.17, 19.03, "...128 values..."]
    }
  ],

  "persons": [
    {
      "id": 26867,
      "pose": "standing",
      "confidence": 0.9,
      "facing": 0.0,
      "motion_score": 45.0,
      "zone": "tracked",
      "position": [0.0, 0.0, 0.0],
      "bbox": { "x": 308.0, "y": 226.2, "width": 0.6, "height": 1.0 },
      "keypoints": ["...17 keypoints, see /api/v1/pose/current..."]
    }
  ],

  "signal_field": {
    "grid_size": [20, 1, 20],
    "values": [0.074, 0.081, "...400 values for 20x20 grid..."]
  },

  "vital_signs": {
    "heart_rate_bpm": 74.5,
    "breathing_rate_bpm": 17.7,
    "heartbeat_confidence": 0.404,
    "breathing_confidence": 0.380,
    "signal_quality": 0.5
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `estimated_persons` | int | Person count after multi-node deduplication |
| `classification.motion_level` | string | `"absent"`, `"present_still"`, `"present_moving"`, `"active"` |
| `node_features` | array | Per-node classification and signal features |
| `nodes` | array | Per-node raw CSI amplitude data (128 or 64 subcarriers) |
| `signal_field.values` | array | 400 floats representing a 20×20 spatial RF field map |
| `vital_signs` | object | Real-time heart rate and breathing extracted from CSI |

---

## 4. Pose Estimation

### `GET /api/v1/pose/current`

Current pose for all tracked persons with full 17-keypoint COCO skeleton.

**Response**
```json
{
  "source": "esp32",
  "timestamp": 1780112413.134,
  "total_persons": 5,
  "persons": [
    {
      "id": 27024,
      "pose": "standing",
      "confidence": 0.9,
      "facing": 0.0,
      "motion_score": 45.0,
      "zone": "tracked",
      "position": [0.0, 0.0, 0.0],
      "bbox": { "x": 308.0, "y": 226.2, "width": 0.6, "height": 1.0 },
      "keypoints": [
        { "name": "nose",           "x": 308.1, "y": 153.7, "z": -0.163, "confidence": 0.0 },
        { "name": "left_eye",       "x": 302.5, "y": 142.3, "z": -0.163, "confidence": 0.0 },
        { "name": "right_eye",      "x": 313.1, "y": 145.1, "z": -0.163, "confidence": 0.0 },
        { "name": "left_ear",       "x": 290.6, "y": 148.3, "z": -0.163, "confidence": 0.0 },
        { "name": "right_ear",      "x": 324.9, "y": 149.7, "z": -0.163, "confidence": 0.0 },
        { "name": "left_shoulder",  "x": 278.9, "y": 183.4, "z": -0.163, "confidence": 0.0 },
        { "name": "right_shoulder", "x": 337.5, "y": 180.0, "z": -0.163, "confidence": 0.0 },
        { "name": "left_elbow",     "x": 261.9, "y": 215.7, "z": -0.163, "confidence": 0.0 },
        { "name": "right_elbow",    "x": 354.8, "y": 217.7, "z": -0.163, "confidence": 0.0 },
        { "name": "left_wrist",     "x": 260.7, "y": 250.4, "z": -0.163, "confidence": 0.0 },
        { "name": "right_wrist",    "x": 357.0, "y": 254.2, "z": -0.163, "confidence": 0.0 },
        { "name": "left_hip",       "x": 287.7, "y": 253.0, "z": -0.163, "confidence": 0.0 },
        { "name": "right_hip",      "x": 329.6, "y": 253.3, "z": -0.163, "confidence": 0.0 },
        { "name": "left_knee",      "x": 288.9, "y": 302.7, "z": -0.163, "confidence": 0.0 },
        { "name": "right_knee",     "x": 328.5, "y": 301.6, "z": -0.163, "confidence": 0.0 },
        { "name": "left_ankle",     "x": 282.4, "y": 352.4, "z": -0.163, "confidence": 0.0 },
        { "name": "right_ankle",    "x": 334.2, "y": 351.4, "z": -0.163, "confidence": 0.0 }
      ]
    }
  ]
}
```

**Keypoint order:** COCO-17 format — nose, left_eye, right_eye, left_ear, right_ear, left_shoulder, right_shoulder, left_elbow, right_elbow, left_wrist, right_wrist, left_hip, right_hip, left_knee, right_knee, left_ankle, right_ankle

**Coordinate space:** Pixel coordinates on 640×480 reference frame. `z` is signed depth (negative = toward sensor). Per-keypoint `confidence` is 0 when WiFi-only (no camera).

**Pose values:** `"standing"`, `"sitting"`, `"lying"`, `"unknown"`

---

### `GET /api/v1/pose/stats`

Detection statistics accumulated since server start.

**Response**
```json
{
  "source": "esp32",
  "frames_processed": 1000215,
  "total_detections": 0,
  "average_confidence": 0.87
}
```

---

### `GET /api/v1/pose/zones/summary`

Occupancy per named zone.

**Response**
```json
{
  "zones": {
    "zone_1": { "person_count": 0, "status": "monitored" },
    "zone_2": { "person_count": 0, "status": "clear" },
    "zone_3": { "person_count": 0, "status": "clear" },
    "zone_4": { "person_count": 0, "status": "clear" }
  }
}
```

---

## 5. Vital Signs

### `GET /api/v1/vital-signs`

Server-fused vital signs extracted from CSI. Updated every tick.

**Response**
```json
{
  "source": "esp32",
  "tick": 1000198,
  "vital_signs": {
    "heart_rate_bpm": 81.1,
    "breathing_rate_bpm": 12.0,
    "heartbeat_confidence": 0.344,
    "breathing_confidence": 0.421,
    "signal_quality": 0.5
  },
  "buffer_status": {
    "heartbeat_capacity": 150,
    "heartbeat_samples": 0,
    "breathing_capacity": 300,
    "breathing_samples": 0
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `heart_rate_bpm` | float | Estimated heart rate |
| `breathing_rate_bpm` | float | Estimated breathing rate |
| `heartbeat_confidence` | float | 0–1, reliability of heart rate reading |
| `breathing_confidence` | float | 0–1, reliability of breathing rate reading |
| `signal_quality` | float | 0–1 overall CSI signal quality |

---

### `GET /api/v1/edge-vitals`

Vitals computed on the ESP32 node (edge-side processing). Populated when a 60 GHz mmWave module (MR60BHA2) is connected.

**Response**
```json
{
  "status": "ok",
  "edge_vitals": {
    "node_id": 3,
    "timestamp_ms": 10782380,
    "n_persons": 4,
    "presence": false,
    "presence_score": 12.15,
    "motion": true,
    "motion_energy": 12.15,
    "heartrate_bpm": 71.2,
    "breathing_rate_bpm": 17.7,
    "fall_detected": false,
    "radar_present": false,
    "radar_type": 0,
    "radar_targets": 0,
    "radar_dist_cm": 0,
    "rssi": -20
  }
}
```

---

## 6. Nodes & Mesh

### `GET /api/v1/nodes`

All connected ESP32 sensing nodes with real-time status.

**Response** (4-node setup)
```json
{
  "total": 4,
  "nodes": [
    {
      "node_id": 2,
      "status": "active",
      "rssi_dbm": -28.0,
      "last_seen_ms": 7,
      "motion_level": "present_moving",
      "person_count": 1,
      "radar_present": false,
      "radar_type": "none",
      "radar_dist_cm": 0
    },
    {
      "node_id": 3,
      "status": "active",
      "rssi_dbm": -21.0,
      "last_seen_ms": 12,
      "motion_level": "present_still",
      "person_count": 1,
      "radar_present": false,
      "radar_type": "none",
      "radar_dist_cm": 0
    },
    {
      "node_id": 7,
      "status": "active",
      "rssi_dbm": -73.0,
      "last_seen_ms": 16,
      "motion_level": "present_moving",
      "person_count": 1,
      "radar_present": false,
      "radar_type": "none",
      "radar_dist_cm": 0
    },
    {
      "node_id": 1,
      "status": "active",
      "rssi_dbm": -72.0,
      "last_seen_ms": 24,
      "motion_level": "present_still",
      "person_count": 1,
      "radar_present": false,
      "radar_type": "none",
      "radar_dist_cm": 0
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `rssi_dbm` | float | Signal strength to Orange Pi (-20 dBm = strong, -90 dBm = weak) |
| `last_seen_ms` | int | Milliseconds since last packet from this node |
| `motion_level` | string | Per-node motion classification |
| `person_count` | int | Persons detected by this node alone (before dedup) |
| `radar_type` | string | `"none"`, `"ld2410"`, `"mr60bha2"` |

---

### `GET /api/v1/nodes/:id/sync`

Request a mesh sync from a specific node.

**Response (node not yet synced)**
```json
{
  "node_id": 1,
  "error": "no_sync",
  "hint": "node hasn't emitted a sync packet yet (no mesh peer or not v0.6.9+)"
}
```

**Note:** Requires firmware v0.6.9+ with mesh sync enabled.

---

### `GET /api/v1/mesh`

Mesh peer topology. Populated when nodes are running mesh firmware.

**Response (no mesh active)**
```json
{ "nodes": {}, "total": 0 }
```

---

### `GET /api/v1/mesh/metrics`

Prometheus-format mesh metrics. Note: this endpoint returns **plain text**, not JSON.

**Response**
```
# HELP wifi_densepose_mesh_node_total Per-state node count across the fleet
# TYPE wifi_densepose_mesh_node_total gauge
wifi_densepose_mesh_node_total{state="leader"} 0
wifi_densepose_mesh_node_total{state="follower"} 0
wifi_densepose_mesh_node_total{state="no_sync"} 4
# HELP wifi_densepose_mesh_csi_fps Per-node measured CSI frame rate (Hz)
# TYPE wifi_densepose_mesh_csi_fps gauge
...
```

---

## 7. Models

### `GET /api/v1/models`

List all model files on the device.

**Response**
```json
{ "models": [], "total": 0 }
```

---

### `GET /api/v1/models/active`

Currently loaded model.

**Response (none loaded)**
```json
{ "active": null }
```

---

### `POST /api/v1/models/load`

Load a model by ID.

**Request**
```json
{ "id": "pose-v1" }
```

**Response**
```json
{ "success": true, "loaded": "pose-v1" }
```

---

### `POST /api/v1/models/unload`

Unload the active model.

**Request** — empty body `{}`

**Response**
```json
{ "success": true, "previous": "pose-v1" }
```

---

### `DELETE /api/v1/models/{id}`

Delete a model file. Returns `404` if not found.

---

### `GET /api/v1/models/lora/profiles`

LoRA adapter profiles available on the device.

**Response**
```json
{ "profiles": [] }
```

---

### `POST /api/v1/models/lora/activate`

Activate a LoRA profile for environment adaptation.

**Request**
```json
{ "profile": "office-daytime" }
```

**Response**
```json
{ "success": true, "profile": "office-daytime" }
```

---

### `GET /api/v1/model/info`

Legacy RVF container status.

**Response**
```json
{
  "status": "no_model",
  "message": "No RVF container loaded. Use --load-rvf <path> to load one."
}
```

---

### `GET /api/v1/model/layers`

Progressive model layer loading state.

**Response**
```json
{
  "layer_a": false,
  "layer_b": false,
  "layer_c": false,
  "progress": 0.0,
  "message": "No model loaded with progressive loading"
}
```

---

### `GET /api/v1/model/sona/profiles` / `POST /api/v1/model/sona/activate`

SONA self-optimizing adapter profiles. Currently unused on device.

---

## 8. Recording

### `GET /api/v1/recording/list`

List CSI recordings stored on the device.

**Response** (device has 2 recordings)
```json
{
  "recordings": [
    {
      "id": "overnight-1775217646.csi",
      "name": "overnight-1775217646.csi",
      "path": "data/recordings/overnight-1775217646.csi.jsonl",
      "frames": 253,
      "size_bytes": 252818,
      "status": "completed",
      "modified_epoch": 1778360025
    },
    {
      "id": "pretrain-1775182186.csi",
      "name": "pretrain-1775182186.csi",
      "path": "data/recordings/pretrain-1775182186.csi.jsonl",
      "frames": 3,
      "size_bytes": 2810,
      "status": "completed",
      "modified_epoch": 1778360025
    }
  ]
}
```

---

### `POST /api/v1/recording/start`

Start a new recording session.

**Request**
```json
{ "name": "my-session" }
```

**Response**
```json
{ "success": true, "recording_id": "rec_1780104228" }
```

**Training data naming convention:** Name recordings with `train_<label>` to use them for adaptive classifier retraining:
- `train_absent` — room empty
- `train_present_still` — person(s) standing still
- `train_present_moving` — person(s) walking
- `train_active` — high activity (multiple people moving)

---

### `POST /api/v1/recording/stop`

Stop the current recording.

**Response**
```json
{
  "success": true,
  "recording_id": "rec_1780104228",
  "duration_secs": 45
}
```

---

### `DELETE /api/v1/recording/{id}`

Delete a recording. Returns `404` if not found.

---

## 9. Training

### `GET /api/v1/train/status`

**Response (idle)**
```json
{ "status": "idle", "config": null }
```

---

### `POST /api/v1/train/start`

Start the full training pipeline.

**Request** — empty body `{}`

**Response**
```json
{
  "success": true,
  "status": "running",
  "message": "Training pipeline started. Use GET /api/v1/train/status to monitor."
}
```

---

### `POST /api/v1/train/stop`

Stop training.

**Response**
```json
{ "success": true, "status": "idle" }
```

---

## 10. Adaptive Classifier

The on-device lightweight classifier learns 4 occupancy classes from your environment.

**Classes:** `"absent"`, `"present_still"`, `"present_moving"`, `"active"`

### `GET /api/v1/adaptive/status`

**Response (not loaded)**
```json
{
  "loaded": false,
  "accuracy": null,
  "trained_frames": null,
  "classes": null
}
```

**Response (loaded)**
```json
{
  "loaded": true,
  "version": 1,
  "accuracy": 0.415,
  "trained_frames": 3316,
  "classes": ["absent", "present_still", "present_moving", "active"],
  "class_stats": [
    {
      "label": "absent",
      "count": 862,
      "mean": [66.68, 67.24, 65.03, "...15 features..."],
      "stddev": [64.05, 90.28, 40.16, "..."]
    }
  ]
}
```

---

### `POST /api/v1/adaptive/train`

Retrain the classifier from `train_*` recordings.

**Request** — empty body `{}`

**Response (no training data)**
```json
{
  "success": false,
  "error": "No training samples found. Record data with train_* prefix."
}
```

**Response (success)**
```json
{ "success": true, "trained_frames": 3316, "accuracy": 0.72 }
```

---

### `POST /api/v1/adaptive/unload`

Unload the classifier from memory.

**Response**
```json
{ "success": true, "message": "Adaptive model unloaded." }
```

---

## 11. Calibration

Empty-room baseline calibration improves person-count accuracy for this specific room. Requires ~20 minutes (12,000 frames at 10 Hz) with the room empty.

### `GET /api/v1/calibration/status`

**Response**
```json
{ "active": false, "status": "none" }
```

---

### `POST /api/v1/calibration/start`

**Request** — empty body `{}`

**Response**
```json
{
  "success": true,
  "message": "Calibration started — keep room empty while frames accumulate."
}
```

---

### `POST /api/v1/calibration/stop`

**Response (insufficient frames)**
```json
{
  "success": false,
  "error": "Insufficient calibration frames: need 12000, got 0"
}
```

**Response (complete)**
```json
{ "success": true, "frames_collected": 12000 }
```

---

## 12. Configuration

### `GET /api/v1/config/dedup-factor`

Person-count deduplication factor. Applied as: `estimated_persons = sum_of_node_counts / dedup_factor`.

**Response**
```json
{
  "dedup_factor": 3.0,
  "description": "Divisor for multi-node person count deduplication (sum / factor). Range: 1.0–10.0."
}
```

---

### `POST /api/v1/config/dedup-factor`

Set the dedup factor at runtime.

**Request**
```json
{ "factor": 4.0 }
```

**Response**
```json
{ "status": "ok", "dedup_factor": 4.0 }
```

*Guidelines: 1-node → `1.0`, 2-node → `2.0`, 4-node → `3.0`–`4.0`. Range: 1.0–10.0.*

---

### `POST /api/v1/config/ground-truth`

Tell the server the true person count so it auto-computes the optimal dedup factor.

**Request**
```json
{ "count": 5 }
```

**Response**
```json
{
  "status": "ok",
  "ground_truth": 5,
  "raw_sum": 4,
  "computed_dedup_factor": 3.0
}
```

---

## 13. Edge & WASM

### `GET /api/v1/edge/registry`

Edge WASM module registry fetched from cloud.

**Response**
```json
{
  "modules": [],
  "source": "https://storage.googleapis.com/cognitum-apps/app-registry.json",
  "ttl_seconds": 3600
}
```

---

### `GET /api/v1/wasm-events`

Events emitted by WASM edge modules running on ESP32 nodes.

**Response (no module loaded)**
```json
{
  "status": "no_data",
  "message": "No WASM output packet received yet. Upload and start a .wasm module on the ESP32.",
  "wasm_events": null
}
```

---

## 14. Introspection

### `GET /api/v1/introspection/snapshot`

Real-time signal dynamics analysis using Lyapunov exponents. Detects environmental regime changes (movement patterns, environmental interference).

**Response**
```json
{
  "timestamp_ns": 1780112447872761589,
  "frame_count": 969427,
  "regime": "chaotic",
  "lyapunov_exponent": 0.851,
  "attractor_dim": 1,
  "attractor_confidence": 1.0,
  "regime_changed": false,
  "top_k_similarity": []
}
```

| Field | Type | Description |
|-------|------|-------------|
| `regime` | string | `"stable"` (empty room), `"chaotic"` (active), `"unknown"` |
| `lyapunov_exponent` | float | Positive = chaotic/dynamic signal; near 0 = static |
| `attractor_confidence` | float | 0–1, confidence in regime classification |
| `regime_changed` | bool | `true` on the tick when regime transitions |

*The live device currently shows `regime: "chaotic"` with `lyapunov: 0.851` — consistent with 5 people present.*

---

## 15. WebSockets

### `ws://<device-ip>:3023/ws/sensing` *(primary high-frequency stream)*

Raw sensing data pushed every 100ms. Same JSON schema as `/api/v1/sensing/latest`. Best for live dashboards.

**JavaScript example**
```javascript
const ws = new WebSocket('ws://192.168.7.205:3023/ws/sensing');
ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log(`Persons: ${data.estimated_persons}, Motion: ${data.classification.motion_level}`);
  console.log(`HR: ${data.vital_signs.heart_rate_bpm} bpm`);
};
```

---

### `ws://<device-ip>:3022/ws/sensing` *(HTTP-port mirror)*

Same stream on the HTTP port. Use this if only port 3022 is accessible.

---

### `ws://<device-ip>:3022/api/v1/stream/pose`

Pose-only stream — only keypoint data, no CSI amplitudes. Lighter weight for skeleton rendering.

---

### `ws://<device-ip>:3022/ws/introspection`

Regime change events. Subscribe to get notified when the environment transitions (e.g., room goes from empty to occupied).

---

### `GET /api/v1/stream/status`

Check stream without opening a WebSocket.

**Response**
```json
{
  "active": true,
  "source": "esp32",
  "fps": 10,
  "clients": 0
}
```

---

## 16. Error Handling

All errors return JSON. HTTP status codes follow REST conventions:

| Status | Meaning |
|--------|---------|
| `200` | Success — but always check `"success": false` in body for soft errors |
| `401` | Missing or invalid bearer token |
| `404` | Resource not found |
| `422` | Invalid request body |
| `500` | Server error |

**Soft error pattern** — some POST endpoints always return 200 but signal failure in the body:
```json
{ "success": false, "error": "descriptive message" }
```

**Auth error**
```json
{ "error": "Unauthorized" }
```

---

## Quick Reference — All Endpoints

| Method | Path | Content-Type | Description |
|--------|------|-------------|-------------|
| GET | `/health` | JSON | Basic health + tick |
| GET | `/health/health` | JSON | Component breakdown |
| GET | `/health/live` | JSON | Liveness probe |
| GET | `/health/ready` | JSON | Readiness probe |
| GET | `/health/version` | JSON | Version info |
| GET | `/health/metrics` | JSON | CPU/mem/disk |
| GET | `/api/v1/info` | JSON | Server capabilities |
| GET | `/api/v1/status` | JSON | Ready status (alias) |
| GET | `/api/v1/metrics` | JSON | System metrics (alias) |
| GET | `/api/v1/sensing/latest` | JSON | **Full fused snapshot — primary data endpoint** |
| GET | `/api/v1/nodes` | JSON | All ESP32 nodes + status |
| GET | `/api/v1/nodes/:id/sync` | JSON | Sync a node |
| GET | `/api/v1/mesh` | JSON | Mesh topology |
| GET | `/api/v1/mesh/metrics` | **Prometheus text** | Mesh metrics |
| GET | `/api/v1/vital-signs` | JSON | Heart rate + breathing |
| GET | `/api/v1/edge-vitals` | JSON | ESP32-computed vitals |
| GET | `/api/v1/edge/registry` | JSON | WASM module registry |
| GET | `/api/v1/wasm-events` | JSON | WASM event log |
| GET | `/api/v1/pose/current` | JSON | 17-keypoint pose all persons |
| GET | `/api/v1/pose/stats` | JSON | Detection stats |
| GET | `/api/v1/pose/zones/summary` | JSON | Zone occupancy |
| GET | `/api/v1/stream/status` | JSON | WebSocket stream health |
| WS | `:3023/ws/sensing` | — | **Primary sensing stream (10 Hz)** |
| WS | `:3022/ws/sensing` | — | Sensing stream mirror |
| WS | `:3022/api/v1/stream/pose` | — | Pose-only stream |
| WS | `:3022/ws/introspection` | — | Regime change events |
| GET | `/api/v1/model/info` | JSON | RVF container info |
| GET | `/api/v1/model/layers` | JSON | Progressive load status |
| GET | `/api/v1/model/segments` | JSON | Model segments |
| GET | `/api/v1/model/sona/profiles` | JSON | SONA profiles |
| POST | `/api/v1/model/sona/activate` | JSON | Activate SONA profile |
| GET | `/api/v1/models` | JSON | All model files |
| GET | `/api/v1/models/active` | JSON | Active model |
| POST | `/api/v1/models/load` | JSON | Load a model |
| POST | `/api/v1/models/unload` | JSON | Unload model |
| DELETE | `/api/v1/models/{id}` | — | Delete a model (404 if missing) |
| GET | `/api/v1/models/lora/profiles` | JSON | LoRA adapter profiles |
| POST | `/api/v1/models/lora/activate` | JSON | Activate LoRA profile |
| GET | `/api/v1/recording/list` | JSON | List recordings |
| POST | `/api/v1/recording/start` | JSON | Start recording |
| POST | `/api/v1/recording/stop` | JSON | Stop recording |
| DELETE | `/api/v1/recording/{id}` | — | Delete recording (404 if missing) |
| GET | `/api/v1/train/status` | JSON | Training state |
| POST | `/api/v1/train/start` | JSON | Start training pipeline |
| POST | `/api/v1/train/stop` | JSON | Stop training |
| GET | `/api/v1/adaptive/status` | JSON | Classifier state |
| POST | `/api/v1/adaptive/train` | JSON | Retrain from recordings |
| POST | `/api/v1/adaptive/unload` | JSON | Unload classifier |
| GET | `/api/v1/calibration/status` | JSON | Calibration state |
| POST | `/api/v1/calibration/start` | JSON | Start empty-room calibration |
| POST | `/api/v1/calibration/stop` | JSON | Apply calibration baseline |
| GET | `/api/v1/config/dedup-factor` | JSON | Get dedup factor |
| POST | `/api/v1/config/dedup-factor` | JSON | Set dedup factor |
| POST | `/api/v1/config/ground-truth` | JSON | Auto-compute dedup factor |
| GET | `/api/v1/introspection/snapshot` | JSON | Lyapunov signal dynamics |
