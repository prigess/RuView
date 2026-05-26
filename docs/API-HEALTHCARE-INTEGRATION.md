# RuView API Reference & Healthcare Integration Guide

## Complete API Reference

### Base URLs
- **HTTP API**: `http://<HOST>:8080/api/v1/`
- **WebSocket**: `ws://<HOST>:8765/ws/sensing` or `ws://<HOST>:8080/ws/sensing`

---

## Health & Status Endpoints

| Endpoint | Method | Description | Healthcare Use |
|----------|--------|-------------|----------------|
| `/health` | GET | Basic health check | Load balancer probes |
| `/health/live` | GET | Liveness probe | Kubernetes readiness |
| `/health/ready` | GET | Readiness probe | Service discovery |
| `/health/version` | GET | Software version | Audit compliance |
| `/health/metrics` | GET | Prometheus metrics | Monitoring dashboards |
| `/api/v1/status` | GET | Server status | Integration health check |
| `/api/v1/info` | GET | API info & capabilities | Client initialization |

### Example: Health Check
```bash
curl http://192.168.7.205:8080/health
```
```json
{
  "status": "ok",
  "uptime_seconds": 3600,
  "version": "0.7.0"
}
```

---

## Core Sensing Endpoints (Healthcare Critical)

### 1. Real-Time Sensing Data
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/sensing/latest` | GET | Latest sensing snapshot |

**Response:**
```json
{
  "timestamp": 1716652800.123,
  "source": "esp32",
  "classification": {
    "motion_level": "present_moving",
    "presence": true,
    "confidence": 0.85
  },
  "features": {
    "mean_rssi": -52.3,
    "variance": 12.5,
    "motion_band_power": 0.45,
    "breathing_band_power": 0.23,
    "dominant_freq_hz": 0.25,
    "change_points": 3,
    "spectral_power": 0.67
  },
  "vital_signs": {
    "breathing_rate_bpm": 14.5,
    "heart_rate_bpm": 72.0,
    "breathing_confidence": 0.7,
    "heart_rate_confidence": 0.5
  },
  "estimated_persons": 1,
  "signal_field": {...}
}
```

**Healthcare Use:**
- Continuous patient monitoring
- Fall risk assessment (motion patterns)
- Sleep quality tracking (breathing rate)
- Occupancy for infection control

---

### 2. Vital Signs Endpoint
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/vital-signs` | GET | Extracted vital sign estimates |
| `/api/v1/edge-vitals` | GET | Edge-processed vitals from ESP32 |

**Response:**
```json
{
  "breathing_rate_bpm": 14.5,
  "breathing_confidence": 0.78,
  "heart_rate_bpm": 72.0,
  "heart_rate_confidence": 0.52,
  "signal_quality": 0.85,
  "timestamp": 1716652800.123
}
```

**Healthcare Use:**
- Remote patient monitoring (RPM)
- Post-surgical recovery tracking
- Chronic disease management (COPD, heart failure)
- Sleep apnea screening

---

### 3. Node Status (Multi-Sensor)
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/nodes` | GET | List all connected ESP32 nodes |
| `/api/v1/nodes/:id/sync` | GET | Node sync status for mesh |
| `/api/v1/mesh` | GET | Mesh topology status |
| `/api/v1/mesh/metrics` | GET | Mesh performance metrics |

**Response:**
```json
{
  "nodes": [
    {
      "node_id": 1,
      "rssi_dbm": -45,
      "position": [0.0, 0.0, 1.5],
      "subcarrier_count": 56,
      "last_seen_ms": 100,
      "radar_type": 2,
      "radar_targets": 1,
      "radar_dist_cm": 245
    },
    {
      "node_id": 2,
      "rssi_dbm": -52,
      "position": [3.0, 0.0, 1.5],
      "subcarrier_count": 56,
      "last_seen_ms": 150
    }
  ]
}
```

**Healthcare Use:**
- Multi-room coverage verification
- System reliability monitoring
- Sensor placement optimization

---

### 4. Pose & Activity Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/pose/current` | GET | Current pose keypoints |
| `/api/v1/pose/stats` | GET | Activity statistics |
| `/api/v1/pose/zones/summary` | GET | Zone-based activity summary |

**Response (pose/current):**
```json
{
  "persons": [
    {
      "id": 1,
      "confidence": 0.85,
      "pose": "standing",
      "position": [2.5, 1.8, 0.0],
      "motion_score": 45.2,
      "facing": 1.57,
      "keypoints": [
        {"name": "nose", "x": 2.5, "y": 1.8, "z": 1.7, "confidence": 0.9},
        {"name": "left_shoulder", "x": 2.3, "y": 1.7, "z": 1.5, "confidence": 0.85}
      ],
      "zone": "bedroom"
    }
  ],
  "estimated_persons": 1
}
```

**Healthcare Use:**
- Fall detection (pose change from standing to floor)
- Gait analysis for mobility assessment
- Activity recognition for ADL tracking
- Wandering detection (dementia care)

---

## Recording & Training Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/recording/list` | GET | List saved recordings |
| `/api/v1/recording/start` | POST | Start recording CSI data |
| `/api/v1/recording/stop` | POST | Stop and save recording |
| `/api/v1/recording/{id}` | DELETE | Delete a recording |
| `/api/v1/train/status` | GET | Training job status |
| `/api/v1/train/start` | POST | Start model training |
| `/api/v1/train/stop` | POST | Stop training |

**Start Recording:**
```bash
curl -X POST http://192.168.7.205:8080/api/v1/recording/start \
  -H "Content-Type: application/json" \
  -d '{"label": "patient_walking", "duration_seconds": 300}'
```

**Healthcare Use:**
- Building patient-specific activity profiles
- Creating labeled datasets for fall detection
- Training personalized models

---

## Calibration Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/calibration/start` | POST | Start field calibration |
| `/api/v1/calibration/stop` | POST | Stop calibration |
| `/api/v1/calibration/status` | GET | Calibration progress |

**Usage:**
```bash
# Start calibration (room must be empty)
curl -X POST http://192.168.7.205:8080/api/v1/calibration/start

# Check status
curl http://192.168.7.205:8080/api/v1/calibration/status
```

**Response:**
```json
{
  "status": "calibrating",
  "progress_percent": 45,
  "frames_collected": 450,
  "estimated_remaining_seconds": 165
}
```

---

## Configuration Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/config/dedup-factor` | GET/POST | Multi-node person deduplication |
| `/api/v1/config/ground-truth` | POST | Set ground truth for accuracy tuning |

---

## WebSocket Streams

### 1. Real-Time Sensing Stream
```javascript
const ws = new WebSocket('ws://192.168.7.205:8765/ws/sensing');

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Presence:', data.classification.presence);
  console.log('Motion:', data.classification.motion_level);
  console.log('Breathing:', data.vital_signs?.breathing_rate_bpm);
};
```

**Message Format:**
```json
{
  "type": "sensing",
  "timestamp": 1716652800.123,
  "source": "esp32",
  "tick": 12345,
  "nodes": [...],
  "features": {...},
  "classification": {
    "motion_level": "present_still",
    "presence": true,
    "confidence": 0.92
  },
  "vital_signs": {
    "breathing_rate_bpm": 14.2,
    "heart_rate_bpm": 68.0,
    "breathing_confidence": 0.8,
    "heart_rate_confidence": 0.6
  },
  "persons": [...],
  "estimated_persons": 1
}
```

### 2. Pose Stream
```javascript
const ws = new WebSocket('ws://192.168.7.205:8080/api/v1/stream/pose');
```

### 3. Introspection Stream (Debug)
```javascript
const ws = new WebSocket('ws://192.168.7.205:8080/ws/introspection');
```

---

## Model Management Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/models` | GET | List available models |
| `/api/v1/models/active` | GET | Get active model info |
| `/api/v1/models/load` | POST | Load a model |
| `/api/v1/models/unload` | POST | Unload current model |
| `/api/v1/models/{id}` | DELETE | Delete a model |
| `/api/v1/model/info` | GET | Current model info (RVF) |
| `/api/v1/model/layers` | GET | Model layer info |
| `/api/v1/model/segments` | GET | Model segments |

---

## Adaptive Learning Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/adaptive/train` | POST | Train adaptive classifier |
| `/api/v1/adaptive/status` | GET | Adaptive training status |
| `/api/v1/adaptive/unload` | POST | Unload adaptive model |
| `/api/v1/model/sona/profiles` | GET | List SONA profiles |
| `/api/v1/model/sona/activate` | POST | Activate SONA profile |

---

## Edge Module Registry

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/edge/registry` | GET | List available edge modules |
| `/api/v1/wasm-events` | GET | WASM runtime events |

---

# Healthcare Integration Architecture

## Integration Patterns

### Pattern 1: Polling (Simple)
```
┌─────────────────┐     HTTP GET      ┌─────────────────┐
│  Healthcare App │ ───────────────── │  RuView Server  │
│  (EHR, Nurse    │  /sensing/latest  │  (Orange Pi)    │
│   Station)      │ ◄───────────────  │                 │
└─────────────────┘    JSON Response  └─────────────────┘
```

```python
import requests
import time

while True:
    response = requests.get('http://192.168.7.205:8080/api/v1/sensing/latest')
    data = response.json()

    if data['classification']['presence']:
        print(f"Patient present, motion: {data['classification']['motion_level']}")

        if 'vital_signs' in data:
            print(f"Breathing: {data['vital_signs']['breathing_rate_bpm']} bpm")

    time.sleep(5)  # Poll every 5 seconds
```

### Pattern 2: WebSocket (Real-Time)
```
┌─────────────────┐    WebSocket     ┌─────────────────┐
│  Healthcare App │ ═══════════════  │  RuView Server  │
│  (Dashboard,    │  /ws/sensing     │  (Orange Pi)    │
│   Alerting)     │ ◄═══════════════ │                 │
└─────────────────┘   Continuous     └─────────────────┘
```

```javascript
// Real-time monitoring dashboard
const ws = new WebSocket('ws://192.168.7.205:8765/ws/sensing');

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);

  // Check for alerts
  if (data.classification.motion_level === 'absent' && previouslyPresent) {
    triggerAlert('POSSIBLE_FALL', data);
  }

  if (data.vital_signs?.breathing_rate_bpm < 8) {
    triggerAlert('LOW_BREATHING_RATE', data);
  }

  updateDashboard(data);
};
```

### Pattern 3: Event-Driven (MQTT/Webhook)
```
┌─────────────────┐                  ┌─────────────────┐
│  Healthcare App │                  │  RuView Server  │
│                 │                  │                 │
└────────┬────────┘                  └────────┬────────┘
         │                                    │
         │         ┌──────────────┐           │
         └────────►│  MQTT Broker │◄──────────┘
                   │  / Webhook   │
                   └──────────────┘
```

---

## Healthcare Use Cases

### 1. Remote Patient Monitoring (RPM)

**Objective:** Continuous monitoring of vital signs for chronic disease patients

**API Integration:**
```python
class RPMMonitor:
    def __init__(self, ruview_host, patient_id):
        self.ws = websocket.WebSocketApp(
            f'ws://{ruview_host}:8765/ws/sensing',
            on_message=self.on_message
        )
        self.patient_id = patient_id

    def on_message(self, ws, message):
        data = json.loads(message)

        # Extract vital signs
        vitals = {
            'patient_id': self.patient_id,
            'timestamp': data['timestamp'],
            'breathing_rate': data['vital_signs'].get('breathing_rate_bpm'),
            'heart_rate': data['vital_signs'].get('heart_rate_bpm'),
            'activity_level': data['classification']['motion_level'],
            'presence': data['classification']['presence']
        }

        # Send to EHR/FHIR server
        self.send_to_ehr(vitals)

        # Check thresholds
        self.check_alerts(vitals)
```

### 2. Fall Detection & Alert

**Objective:** Detect falls and alert caregivers immediately

**API Integration:**
```python
class FallDetector:
    def __init__(self, ruview_host):
        self.previous_state = 'standing'
        self.motion_history = []

    def process_sensing_data(self, data):
        current_motion = data['classification']['motion_level']

        # Detect sudden absence after movement
        self.motion_history.append(current_motion)
        if len(self.motion_history) > 10:
            self.motion_history.pop(0)

        # Fall detection logic
        if self.detect_fall_pattern():
            return {
                'alert_type': 'FALL_DETECTED',
                'confidence': self.calculate_confidence(),
                'timestamp': data['timestamp'],
                'location': self.get_location(data)
            }

        return None

    def detect_fall_pattern(self):
        # Pattern: active movement -> sudden stillness at low position
        if len(self.motion_history) >= 5:
            recent = self.motion_history[-5:]
            if recent[:3].count('active') >= 2 and recent[-2:].count('present_still') >= 2:
                return True
        return False
```

### 3. Sleep Quality Monitoring

**Objective:** Track sleep patterns and breathing during sleep

```python
class SleepMonitor:
    def __init__(self):
        self.sleep_session = None
        self.breathing_samples = []

    def analyze_sleep(self, data):
        if not data['classification']['presence']:
            return None

        motion = data['classification']['motion_level']
        breathing = data['vital_signs'].get('breathing_rate_bpm', 0)

        # Track breathing patterns
        if motion == 'present_still' and breathing > 0:
            self.breathing_samples.append({
                'timestamp': data['timestamp'],
                'breathing_rate': breathing,
                'confidence': data['vital_signs'].get('breathing_confidence', 0)
            })

        return {
            'sleep_detected': motion == 'present_still',
            'breathing_rate': breathing,
            'restlessness': self.calculate_restlessness(),
            'possible_apnea_events': self.detect_apnea_patterns()
        }
```

### 4. Occupancy & Infection Control

**Objective:** Track room occupancy for hospital infection control

```python
class OccupancyTracker:
    def __init__(self, ruview_hosts):
        self.rooms = {}
        for host in ruview_hosts:
            self.rooms[host['room_id']] = {
                'host': host['ip'],
                'occupancy': 0,
                'last_update': None
            }

    def get_facility_occupancy(self):
        occupancy_report = []

        for room_id, room in self.rooms.items():
            response = requests.get(f"http://{room['host']}:8080/api/v1/sensing/latest")
            data = response.json()

            occupancy_report.append({
                'room_id': room_id,
                'occupied': data['classification']['presence'],
                'person_count': data.get('estimated_persons', 0),
                'activity_level': data['classification']['motion_level'],
                'timestamp': data['timestamp']
            })

        return occupancy_report
```

---

## FHIR Integration Example

```python
from fhir.resources.observation import Observation
from fhir.resources.patient import Patient

class FHIRBridge:
    def __init__(self, fhir_server_url, ruview_host):
        self.fhir_url = fhir_server_url
        self.ruview_host = ruview_host

    def create_vital_observation(self, patient_id, ruview_data):
        """Convert RuView data to FHIR Observation"""

        # Breathing Rate Observation
        if ruview_data['vital_signs'].get('breathing_rate_bpm'):
            obs = Observation(
                status="final",
                code={
                    "coding": [{
                        "system": "http://loinc.org",
                        "code": "9279-1",
                        "display": "Respiratory rate"
                    }]
                },
                subject={"reference": f"Patient/{patient_id}"},
                valueQuantity={
                    "value": ruview_data['vital_signs']['breathing_rate_bpm'],
                    "unit": "/min",
                    "system": "http://unitsofmeasure.org",
                    "code": "/min"
                },
                effectiveDateTime=datetime.fromtimestamp(
                    ruview_data['timestamp']
                ).isoformat()
            )

            # Post to FHIR server
            requests.post(
                f"{self.fhir_url}/Observation",
                json=obs.dict()
            )
```

---

## Security Considerations for Healthcare

### 1. API Authentication
Set `RUVIEW_API_TOKEN` environment variable:
```bash
export RUVIEW_API_TOKEN="your-secure-token-here"
./scripts/start-server.sh
```

All `/api/v1/*` endpoints will require:
```
Authorization: Bearer your-secure-token-here
```

### 2. HTTPS/TLS
Use a reverse proxy (nginx) for TLS termination:
```nginx
server {
    listen 443 ssl;
    server_name ruview.hospital.local;

    ssl_certificate /etc/ssl/certs/ruview.crt;
    ssl_certificate_key /etc/ssl/private/ruview.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### 3. Network Segmentation
- Place RuView server on isolated VLAN
- Use firewall rules to restrict access to authorized systems only
- Encrypt UDP traffic between ESP32 nodes and server (future: DTLS)

### 4. Audit Logging
All API requests are logged. Integrate with SIEM:
```bash
# View access logs
journalctl -u ruview-sensing -f
```

---

## Quick Integration Checklist

- [ ] Identify healthcare use case (RPM, fall detection, sleep, occupancy)
- [ ] Choose integration pattern (polling, WebSocket, event-driven)
- [ ] Set up network access to RuView server
- [ ] Implement authentication (API token)
- [ ] Map RuView data to healthcare data model (FHIR, HL7)
- [ ] Implement alerting thresholds
- [ ] Test with real scenarios
- [ ] Document for clinical staff
- [ ] Set up monitoring and audit logging
