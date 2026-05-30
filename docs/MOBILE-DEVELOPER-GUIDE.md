# RuView Mobile Developer Guide

Build a mobile app on top of the RuView sensing server running on an Orange Pi with 4 ESP32 WiFi nodes.

**Prerequisites:** The device is on your local network at a known IP. See `API-REFERENCE.md` for the full endpoint catalog.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Quickstart — First Data in 5 Minutes](#2-quickstart--first-data-in-5-minutes)
3. [WebSocket Integration](#3-websocket-integration)
4. [Use Case Recipes](#4-use-case-recipes)
   - [Room Occupancy Screen](#41-room-occupancy-screen)
   - [Vital Signs Monitor](#42-vital-signs-monitor)
   - [Pose Skeleton Overlay](#43-pose-skeleton-overlay)
   - [Node Health Dashboard](#44-node-health-dashboard)
   - [Zone Occupancy Map](#45-zone-occupancy-map)
5. [Training RuView for Your Environment](#5-training-ruview-for-your-environment)
   - [Step 1 — Empty-Room Calibration](#51-step-1--empty-room-calibration)
   - [Step 2 — Record Training Data](#52-step-2--record-training-data)
   - [Step 3 — Retrain the Adaptive Classifier](#53-step-3--retrain-the-adaptive-classifier)
   - [Step 4 — Tune the Dedup Factor](#54-step-4--tune-the-dedup-factor)
   - [Building a Training Flow in Your App](#55-building-a-training-flow-in-your-app)
6. [Data Interpretation Guide](#6-data-interpretation-guide)
7. [Connection Management](#7-connection-management)
8. [Handling Offline & Stale Data](#8-handling-offline--stale-data)

---

## 1. Architecture Overview

```
Orange Pi (192.168.7.205)
├── :3022  HTTP REST API  ─── one-off queries, config, recordings
└── :3023  WebSocket      ─── live sensing stream (10 Hz, always-on)
```

**The golden rule: use WebSocket for live data, REST for everything else.**

The WebSocket pushes a full sensing snapshot every 100ms. It contains persons, vitals, per-node status, and the signal field — everything you need for a live screen. Don't poll REST endpoints for live data; you'll get the same data with extra latency.

Use REST for:
- App launch checks (`GET /health`, `GET /api/v1/info`)
- Configuration (`POST /api/v1/config/dedup-factor`)
- Recording management
- Zone summaries that don't need to update in real time

**Data flow for a typical live screen:**

```
App launch
  └─ GET /health              → confirm device is reachable, check source="esp32"
  └─ GET /api/v1/nodes        → display which nodes are active
  └─ Open WebSocket :3023     → start receiving live data
       └─ onMessage           → update UI at 10 Hz
```

---

## 2. Quickstart — First Data in 5 Minutes

### Step 1: Verify the device is up

```bash
curl http://192.168.7.205:3022/health
# {"clients":0,"source":"esp32","status":"ok","tick":997606}
```

`source: "esp32"` = real hardware. `source: "simulate"` = no ESP32 nodes connected.

### Step 2: Check what's happening right now

```bash
curl http://192.168.7.205:3022/api/v1/sensing/latest | python3 -m json.tool
```

You'll see `estimated_persons`, `classification.motion_level`, and live `vital_signs`.

### Step 3: Open the WebSocket stream

```bash
# Using websocat (brew install websocat)
websocat ws://192.168.7.205:3023/ws/sensing
```

You'll see a JSON object pushed every 100ms.

### Step 4: Open the UI

Navigate to `http://192.168.7.205:3022/ui/index.html` to see the built-in observatory.

---

## 3. WebSocket Integration

### iOS — Swift

```swift
import Foundation

class RuViewClient: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    
    // Callbacks your UI subscribes to
    var onSensingUpdate: ((SensingSnapshot) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    override init() {
        session = URLSession(configuration: .default)
        super.init()
    }

    func connect(host: String) {
        let url = URL(string: "ws://\(host):3023/ws/sensing")!
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.delegate = self
        webSocketTask?.resume()
        receiveLoop()
        onConnectionChange?(true)
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        onConnectionChange?(false)
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let snapshot = try? JSONDecoder().decode(SensingSnapshot.self, from: data) {
                    DispatchQueue.main.async {
                        self?.onSensingUpdate?(snapshot)
                    }
                }
                self?.receiveLoop()  // keep listening
            case .failure:
                self?.onConnectionChange?(false)
                // reconnect after delay — see Section 6
            }
        }
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onConnectionChange?(false)
    }
}
```

**Data models:**

```swift
struct SensingSnapshot: Decodable {
    let source: String           // "esp32" or "simulate"
    let tick: Int
    let timestamp: Double
    let estimatedPersons: Int
    let classification: Classification
    let vitalSigns: VitalSigns?
    let persons: [Person]
    let nodeFeatures: [NodeFeature]

    enum CodingKeys: String, CodingKey {
        case source, tick, timestamp, persons
        case estimatedPersons = "estimated_persons"
        case classification
        case vitalSigns = "vital_signs"
        case nodeFeatures = "node_features"
    }
}

struct Classification: Decodable {
    let presence: Bool
    let motionLevel: String   // "absent" | "present_still" | "present_moving" | "active"
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case presence, confidence
        case motionLevel = "motion_level"
    }
}

struct VitalSigns: Decodable {
    let heartRateBpm: Double
    let breathingRateBpm: Double
    let heartbeatConfidence: Double
    let breathingConfidence: Double
    let signalQuality: Double

    enum CodingKeys: String, CodingKey {
        case heartRateBpm = "heart_rate_bpm"
        case breathingRateBpm = "breathing_rate_bpm"
        case heartbeatConfidence = "heartbeat_confidence"
        case breathingConfidence = "breathing_confidence"
        case signalQuality = "signal_quality"
    }
}

struct Person: Decodable {
    let id: Int
    let pose: String        // "standing" | "sitting" | "lying" | "unknown"
    let confidence: Double
    let motionScore: Double
    let zone: String
    let bbox: BoundingBox
    let keypoints: [Keypoint]

    enum CodingKeys: String, CodingKey {
        case id, pose, confidence, zone, bbox, keypoints
        case motionScore = "motion_score"
    }
}

struct Keypoint: Decodable {
    let name: String
    let x: Double
    let y: Double
    let z: Double
    let confidence: Double
}

struct BoundingBox: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct NodeFeature: Decodable {
    let nodeId: Int
    let rssiDbm: Double
    let lastSeenMs: Int
    let stale: Bool
    let classification: Classification

    enum CodingKeys: String, CodingKey {
        case stale, classification
        case nodeId = "node_id"
        case rssiDbm = "rssi_dbm"
        case lastSeenMs = "last_seen_ms"
    }
}
```

---

### Android — Kotlin

```kotlin
import okhttp3.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json

class RuViewClient {
    private val client = OkHttpClient()
    private var webSocket: WebSocket? = null
    private val json = Json { ignoreUnknownKeys = true }

    private val _sensing = MutableStateFlow<SensingSnapshot?>(null)
    val sensing: StateFlow<SensingSnapshot?> = _sensing

    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected

    fun connect(host: String) {
        val request = Request.Builder()
            .url("ws://$host:3023/ws/sensing")
            .build()

        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                _connected.value = true
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val snapshot = json.decodeFromString<SensingSnapshot>(text)
                _sensing.value = snapshot
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                _connected.value = false
                // reconnect — see Section 6
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                _connected.value = false
            }
        })
    }

    fun disconnect() {
        webSocket?.close(1000, "App closed")
    }
}
```

**Data models:**

```kotlin
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SensingSnapshot(
    val source: String,
    val tick: Long,
    val timestamp: Double,
    @SerialName("estimated_persons") val estimatedPersons: Int,
    val classification: Classification,
    @SerialName("vital_signs") val vitalSigns: VitalSigns? = null,
    val persons: List<Person> = emptyList(),
    @SerialName("node_features") val nodeFeatures: List<NodeFeature> = emptyList()
)

@Serializable
data class Classification(
    val presence: Boolean,
    @SerialName("motion_level") val motionLevel: String,
    val confidence: Double
)

@Serializable
data class VitalSigns(
    @SerialName("heart_rate_bpm") val heartRateBpm: Double,
    @SerialName("breathing_rate_bpm") val breathingRateBpm: Double,
    @SerialName("heartbeat_confidence") val heartbeatConfidence: Double,
    @SerialName("breathing_confidence") val breathingConfidence: Double,
    @SerialName("signal_quality") val signalQuality: Double
)

@Serializable
data class Person(
    val id: Int,
    val pose: String,
    val confidence: Double,
    @SerialName("motion_score") val motionScore: Double,
    val zone: String,
    val bbox: BoundingBox,
    val keypoints: List<Keypoint>
)

@Serializable
data class Keypoint(
    val name: String,
    val x: Double,
    val y: Double,
    val z: Double,
    val confidence: Double
)

@Serializable
data class BoundingBox(val x: Double, val y: Double, val width: Double, val height: Double)

@Serializable
data class NodeFeature(
    @SerialName("node_id") val nodeId: Int,
    @SerialName("rssi_dbm") val rssiDbm: Double,
    @SerialName("last_seen_ms") val lastSeenMs: Int,
    val stale: Boolean,
    val classification: Classification
)
```

> **Dependency:** Add `com.squareup.okhttp3:okhttp:4.12.0` and `org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3` to `build.gradle`.

---

## 4. Use Case Recipes

### 4.1 Room Occupancy Screen

**Goal:** Show current person count and motion state, updated live.

**Endpoints used:** WebSocket only (after initial health check)

**What to display:**

| Field | Source | Display |
|-------|--------|---------|
| Person count | `estimated_persons` | Large number |
| Motion state | `classification.motion_level` | Badge/label |
| Confidence | `classification.confidence` | Subtitle or color tint |
| Source | `source` | "Live" badge if `"esp32"`, "Demo" if `"simulate"` |

**iOS example:**

```swift
client.onSensingUpdate = { snapshot in
    self.personCountLabel.text = "\(snapshot.estimatedPersons)"
    self.motionLabel.text = snapshot.classification.motionLevel.displayName
    self.motionLabel.backgroundColor = snapshot.classification.motionLevel.color
}

extension String {
    var displayName: String {
        switch self {
        case "absent":          return "Empty"
        case "present_still":   return "Someone here"
        case "present_moving":  return "Movement detected"
        case "active":          return "High activity"
        default:                return self
        }
    }

    var color: UIColor {
        switch self {
        case "absent":          return .systemGray
        case "present_still":   return .systemBlue
        case "present_moving":  return .systemOrange
        case "active":          return .systemRed
        default:                return .systemGray
        }
    }
}
```

**Android Compose example:**

```kotlin
@Composable
fun OccupancyCard(snapshot: SensingSnapshot) {
    val motionColor = when (snapshot.classification.motionLevel) {
        "absent"          -> Color.Gray
        "present_still"   -> Color.Blue
        "present_moving"  -> Color.Yellow
        "active"          -> Color.Red
        else              -> Color.Gray
    }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = "${snapshot.estimatedPersons}",
                style = MaterialTheme.typography.displayLarge
            )
            Text(text = "people detected")
            Spacer(modifier = Modifier.height(8.dp))
            Chip(
                label = { Text(snapshot.classification.motionLevel) },
                colors = ChipDefaults.chipColors(containerColor = motionColor)
            )
        }
    }
}
```

---

### 4.2 Vital Signs Monitor

**Goal:** Show heart rate and breathing rate with confidence indicators.

**Endpoints used:** WebSocket (primary) + `GET /api/v1/vital-signs` for detailed buffer status

**Confidence thresholds to apply in UI:**

| Confidence | What to show |
|-----------|-------------|
| ≥ 0.6 | Value with normal styling |
| 0.3 – 0.59 | Value with `~` prefix or muted styling |
| < 0.3 | `--` or "Measuring…" |

**iOS example:**

```swift
func updateVitals(_ vitals: VitalSigns) {
    heartRateLabel.text = formatVital(
        value: vitals.heartRateBpm,
        confidence: vitals.heartbeatConfidence,
        unit: "bpm"
    )
    breathingLabel.text = formatVital(
        value: vitals.breathingRateBpm,
        confidence: vitals.breathingConfidence,
        unit: "rpm"
    )
    signalQualityBar.progress = Float(vitals.signalQuality)
}

func formatVital(value: Double, confidence: Double, unit: String) -> String {
    guard confidence >= 0.3 else { return "–" }
    let prefix = confidence >= 0.6 ? "" : "~"
    return "\(prefix)\(Int(value)) \(unit)"
}
```

**Kotlin example:**

```kotlin
@Composable
fun VitalSignsRow(vitals: VitalSigns) {
    Row(horizontalArrangement = Arrangement.SpaceEvenly) {
        VitalCard(
            label = "Heart Rate",
            value = vitals.heartRateBpm,
            confidence = vitals.heartbeatConfidence,
            unit = "bpm"
        )
        VitalCard(
            label = "Breathing",
            value = vitals.breathingRateBpm,
            confidence = vitals.breathingConfidence,
            unit = "rpm"
        )
    }
}

@Composable
fun VitalCard(label: String, value: Double, confidence: Double, unit: String) {
    val text = when {
        confidence < 0.3  -> "–"
        confidence < 0.6  -> "~${value.toInt()} $unit"
        else              -> "${value.toInt()} $unit"
    }
    val alpha = if (confidence >= 0.6) 1f else 0.5f

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text, style = MaterialTheme.typography.headlineMedium,
             modifier = Modifier.alpha(alpha))
        Text(label, style = MaterialTheme.typography.labelSmall)
    }
}
```

---

### 4.3 Pose Skeleton Overlay

**Goal:** Render stick-figure skeletons for each detected person on a canvas.

**Endpoint:** WebSocket — use `persons[].keypoints`

**Coordinate system:** Keypoints are in a 640×480 pixel reference frame. Scale to your canvas size:

```
canvasX = keypoint.x * (canvasWidth / 640.0)
canvasY = keypoint.y * (canvasHeight / 480.0)
```

**COCO-17 skeleton connections** (draw a line between each pair):

```swift
let skeletonEdges: [(String, String)] = [
    ("nose", "left_eye"), ("nose", "right_eye"),
    ("left_eye", "left_ear"), ("right_eye", "right_ear"),
    ("left_ear", "left_shoulder"), ("right_ear", "right_shoulder"),
    ("left_shoulder", "right_shoulder"),
    ("left_shoulder", "left_elbow"), ("right_shoulder", "right_elbow"),
    ("left_elbow", "left_wrist"), ("right_elbow", "right_wrist"),
    ("left_shoulder", "left_hip"), ("right_shoulder", "right_hip"),
    ("left_hip", "right_hip"),
    ("left_hip", "left_knee"), ("right_hip", "right_knee"),
    ("left_knee", "left_ankle"), ("right_knee", "right_ankle")
]
```

**iOS — draw on a UIView:**

```swift
class SkeletonView: UIView {
    var persons: [Person] = [] { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scaleX = rect.width / 640.0
        let scaleY = rect.height / 480.0

        for person in persons {
            let kpMap = Dictionary(uniqueKeysWithValues: person.keypoints.map { ($0.name, $0) })

            // Draw bones
            ctx.setStrokeColor(UIColor.systemGreen.cgColor)
            ctx.setLineWidth(2)
            for (fromName, toName) in skeletonEdges {
                guard let from = kpMap[fromName], let to = kpMap[toName] else { continue }
                ctx.move(to: CGPoint(x: from.x * scaleX, y: from.y * scaleY))
                ctx.addLine(to: CGPoint(x: to.x * scaleX, y: to.y * scaleY))
            }
            ctx.strokePath()

            // Draw joints
            ctx.setFillColor(UIColor.systemYellow.cgColor)
            for kp in person.keypoints {
                let dot = CGRect(x: kp.x * scaleX - 3, y: kp.y * scaleY - 3, width: 6, height: 6)
                ctx.fillEllipse(in: dot)
            }
        }
    }
}

// In your view controller:
client.onSensingUpdate = { snapshot in
    self.skeletonView.persons = snapshot.persons
}
```

**Android — draw on a Canvas:**

```kotlin
@Composable
fun SkeletonCanvas(persons: List<Person>, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val scaleX = size.width / 640f
        val scaleY = size.height / 480f

        persons.forEach { person ->
            val kpMap = person.keypoints.associateBy { it.name }

            // Draw bones
            skeletonEdges.forEach { (fromName, toName) ->
                val from = kpMap[fromName] ?: return@forEach
                val to = kpMap[toName] ?: return@forEach
                drawLine(
                    color = Color.Green,
                    start = Offset(from.x.toFloat() * scaleX, from.y.toFloat() * scaleY),
                    end = Offset(to.x.toFloat() * scaleX, to.y.toFloat() * scaleY),
                    strokeWidth = 3f
                )
            }

            // Draw joints
            person.keypoints.forEach { kp ->
                drawCircle(
                    color = Color.Yellow,
                    radius = 5f,
                    center = Offset(kp.x.toFloat() * scaleX, kp.y.toFloat() * scaleY)
                )
            }
        }
    }
}

val skeletonEdges = listOf(
    "nose" to "left_eye", "nose" to "right_eye",
    "left_eye" to "left_ear", "right_eye" to "right_ear",
    "left_ear" to "left_shoulder", "right_ear" to "right_shoulder",
    "left_shoulder" to "right_shoulder",
    "left_shoulder" to "left_elbow", "right_shoulder" to "right_elbow",
    "left_elbow" to "left_wrist", "right_elbow" to "right_wrist",
    "left_shoulder" to "left_hip", "right_shoulder" to "right_hip",
    "left_hip" to "right_hip",
    "left_hip" to "left_knee", "right_hip" to "right_knee",
    "left_knee" to "left_ankle", "right_knee" to "right_ankle"
)
```

> **Note on per-keypoint confidence:** When `source` is `"esp32"` (WiFi-only, no camera), all keypoint `confidence` values are `0.0`. This is expected — positions are inferred from RF, not visual detection. Don't use keypoint confidence to filter joints; use the person-level `confidence` instead.

---

### 4.4 Node Health Dashboard

**Goal:** Show signal strength and status for each active ESP32 node.

**Endpoints used:**
- `GET /api/v1/nodes` on app launch and every 5 seconds
- WebSocket `node_features` for per-node motion classification

**RSSI signal quality guide:**

| RSSI (dBm) | Quality | Display |
|------------|---------|---------|
| > -50 | Excellent | 4 bars / green |
| -50 to -65 | Good | 3 bars / green |
| -65 to -75 | Fair | 2 bars / yellow |
| -75 to -85 | Poor | 1 bar / orange |
| < -85 | Very poor | 0 bars / red |

```swift
func rssiQuality(_ rssi: Double) -> (bars: Int, color: UIColor) {
    switch rssi {
    case ...(-85): return (0, .systemRed)
    case (-85)...(-75): return (1, .systemOrange)
    case (-75)...(-65): return (2, .systemYellow)
    case (-65)...(-50): return (3, .systemGreen)
    default:            return (4, .systemGreen)
    }
}
```

**Swift — fetch nodes:**

```swift
func fetchNodes(host: String) async throws -> [Node] {
    let url = URL(string: "http://\(host):3022/api/v1/nodes")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let response = try JSONDecoder().decode(NodesResponse.self, from: data)
    return response.nodes
}

struct NodesResponse: Decodable {
    let total: Int
    let nodes: [Node]
}

struct Node: Decodable {
    let nodeId: Int
    let status: String
    let rssiDbm: Double
    let lastSeenMs: Int
    let motionLevel: String
    let radarType: String

    enum CodingKeys: String, CodingKey {
        case status
        case nodeId = "node_id"
        case rssiDbm = "rssi_dbm"
        case lastSeenMs = "last_seen_ms"
        case motionLevel = "motion_level"
        case radarType = "radar_type"
    }
}
```

**Stale detection:** Mark a node as offline if `last_seen_ms > 2000` (hasn't sent data in 2 seconds).

---

### 4.5 Zone Occupancy Map

**Goal:** Display a floor plan with per-zone person counts.

**Endpoints used:**
- `GET /api/v1/pose/zones/summary` — poll every 1–2 seconds (zone data doesn't change at 10 Hz)

```swift
struct ZoneStatus: Decodable {
    let personCount: Int
    let status: String  // "monitored", "clear"

    enum CodingKeys: String, CodingKey {
        case status
        case personCount = "person_count"
    }
}

func fetchZones(host: String) async throws -> [String: ZoneStatus] {
    let url = URL(string: "http://\(host):3022/api/v1/pose/zones/summary")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let json = try JSONDecoder().decode([String: [String: ZoneStatus]].self, from: data)
    return json["zones"] ?? [:]
}
```

**Zone layout** (4 zones mapped to room quadrants):

```
┌─────────────┬─────────────┐
│   zone_1    │   zone_2    │
│  (Q1: NW)   │  (Q2: NE)   │
├─────────────┼─────────────┤
│   zone_3    │   zone_4    │
│  (Q3: SW)   │  (Q4: SE)   │
└─────────────┴─────────────┘
```

Color the zone by `person_count`: 0 = gray, 1 = blue, 2+ = orange.

---

## 5. Training RuView for Your Environment

Out of the box, RuView uses a pre-trained adaptive classifier. But WiFi CSI is highly sensitive to room geometry, furniture, and node placement — accuracy improves significantly when you train it on your specific environment. This section covers the full training workflow and how to expose it in your mobile app.

**Training takes about 25 minutes total and requires physical presence in the space.**

### Why training matters

The classifier distinguishes 4 states: `absent`, `present_still`, `present_moving`, `active`. A freshly deployed device may confuse `present_still` with `absent` or over-count persons because the baseline RF field is unknown. Calibration and training fix this.

**Training sequence:**

```
1. Empty-room calibration   (~20 min)  → sets RF baseline
2. Record labeled sessions  (~4 min)   → captures each occupancy class
3. Retrain classifier       (<1 min)   → applies new model
4. Tune dedup factor        (~1 min)   → fixes person count
```

---

### 5.1 Step 1 — Empty-Room Calibration

**What it does:** Captures the room's RF fingerprint with no people present. This becomes the baseline that the server subtracts from live signals, making it easier to detect people.

**Requirement:** Room must be completely empty. 12,000 frames needed = ~20 minutes at 10 Hz.

**API flow:**

```
POST /api/v1/calibration/start    → start collecting
  ... wait ~20 minutes ...
GET  /api/v1/calibration/status   → poll to check progress
POST /api/v1/calibration/stop     → apply baseline
```

**`GET /api/v1/calibration/status` response during collection:**
```json
{ "active": true, "status": "collecting", "frames": 4200, "target": 12000 }
```

**`POST /api/v1/calibration/stop` response:**
```json
{ "success": true, "frames_collected": 12000 }
```

If you stop early (< 12,000 frames):
```json
{ "success": false, "error": "Insufficient calibration frames: need 12000, got 4200" }
```

**Swift — calibration flow:**

```swift
class CalibrationManager {
    let host: String
    var onProgress: ((Int, Int) -> Void)?   // (collected, target)
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?
    private var pollTimer: Timer?

    func startCalibration() async {
        let url = URL(string: "http://\(host):3022/api/v1/calibration/start")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let res = try JSONDecoder().decode(ActionResponse.self, from: data)
            if res.success { startPolling() }
        } catch { onError?("Failed to start calibration") }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { await self?.pollStatus() }
        }
    }

    private func pollStatus() async {
        let url = URL(string: "http://\(host):3022/api/v1/calibration/status")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let status = try? JSONDecoder().decode(CalibrationStatus.self, from: data) else { return }

        if let frames = status.frames, let target = status.target {
            onProgress?(frames, target)
        }
        if !status.active && status.status == "done" {
            pollTimer?.invalidate()
            onComplete?()
        }
    }

    func stopCalibration() async {
        let url = URL(string: "http://\(host):3022/api/v1/calibration/stop")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let res = try? JSONDecoder().decode(ActionResponse.self, from: data) {
            if res.success { onComplete?() }
            else { onError?(res.error ?? "Calibration failed") }
        }
    }
}

struct CalibrationStatus: Decodable {
    let active: Bool
    let status: String
    let frames: Int?
    let target: Int?
}

struct ActionResponse: Decodable {
    let success: Bool
    let error: String?
}
```

**Kotlin — calibration flow:**

```kotlin
class CalibrationManager(private val host: String, private val scope: CoroutineScope) {
    val progress = MutableStateFlow<Pair<Int, Int>?>(null)  // (collected, target)
    val isComplete = MutableStateFlow(false)
    val error = MutableStateFlow<String?>(null)

    private val http = OkHttpClient()
    private val json = Json { ignoreUnknownKeys = true }
    private var pollJob: Job? = null

    fun startCalibration() {
        scope.launch {
            val req = Request.Builder()
                .url("http://$host:3022/api/v1/calibration/start")
                .post("""{}""".toRequestBody("application/json".toMediaType()))
                .build()
            val res = http.newCall(req).execute()
            if (res.isSuccessful) startPolling()
            else error.value = "Failed to start calibration"
        }
    }

    private fun startPolling() {
        pollJob = scope.launch {
            while (true) {
                delay(5_000)
                val req = Request.Builder()
                    .url("http://$host:3022/api/v1/calibration/status")
                    .build()
                val body = http.newCall(req).execute().body?.string() ?: continue
                val status = json.decodeFromString<CalibrationStatus>(body)
                if (status.frames != null && status.target != null) {
                    progress.value = status.frames to status.target
                }
                if (!status.active && status.status == "done") {
                    isComplete.value = true
                    break
                }
            }
        }
    }

    fun stopCalibration() {
        pollJob?.cancel()
        scope.launch {
            val req = Request.Builder()
                .url("http://$host:3022/api/v1/calibration/stop")
                .post("{}".toRequestBody("application/json".toMediaType()))
                .build()
            val body = http.newCall(req).execute().body?.string()
            val res = body?.let { json.decodeFromString<ActionResponse>(it) }
            if (res?.success == true) isComplete.value = true
            else error.value = res?.error ?: "Calibration failed"
        }
    }
}

@Serializable
data class CalibrationStatus(
    val active: Boolean,
    val status: String,
    val frames: Int? = null,
    val target: Int? = null
)
```

---

### 5.2 Step 2 — Record Training Data

After calibration, record a short session for each occupancy class. The server uses recordings named with a `train_<label>` prefix.

**Required labels:**

| Recording name prefix | Scenario to act out | Duration |
|----------------------|---------------------|----------|
| `train_absent` | Leave the room completely empty | 60 seconds |
| `train_present_still` | Stand/sit still in the room | 60 seconds |
| `train_present_moving` | Walk around normally | 60 seconds |
| `train_active` | Multiple people moving | 60 seconds |

**API flow for one label:**

```
POST /api/v1/recording/start  body: {"name": "train_absent"}
  ... perform the scenario for 60 seconds ...
POST /api/v1/recording/stop
```

**Swift — record one label:**

```swift
func recordLabel(_ label: String, durationSeconds: Int) async throws -> String {
    // Start
    let startURL = URL(string: "http://\(host):3022/api/v1/recording/start")!
    var startReq = URLRequest(url: startURL)
    startReq.httpMethod = "POST"
    startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
    startReq.httpBody = try JSONEncoder().encode(["name": "train_\(label)"])
    let (startData, _) = try await URLSession.shared.data(for: startReq)
    let startRes = try JSONDecoder().decode(RecordingStartResponse.self, from: startData)

    // Wait
    try await Task.sleep(nanoseconds: UInt64(durationSeconds) * 1_000_000_000)

    // Stop
    let stopURL = URL(string: "http://\(host):3022/api/v1/recording/stop")!
    var stopReq = URLRequest(url: stopURL)
    stopReq.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: stopReq)

    return startRes.recordingId
}

struct RecordingStartResponse: Decodable {
    let success: Bool
    let recordingId: String
    enum CodingKeys: String, CodingKey {
        case success
        case recordingId = "recording_id"
    }
}
```

**Kotlin:**

```kotlin
suspend fun recordLabel(host: String, label: String, durationMs: Long): String {
    val http = OkHttpClient()
    val json = Json { ignoreUnknownKeys = true }

    // Start
    val startBody = """{"name":"train_$label"}""".toRequestBody("application/json".toMediaType())
    val startRes = http.newCall(
        Request.Builder().url("http://$host:3022/api/v1/recording/start").post(startBody).build()
    ).execute()
    val recordingId = json.decodeFromString<RecordingStartResponse>(
        startRes.body!!.string()
    ).recordingId

    // Wait
    delay(durationMs)

    // Stop
    http.newCall(
        Request.Builder()
            .url("http://$host:3022/api/v1/recording/stop")
            .post("".toRequestBody())
            .build()
    ).execute()

    return recordingId
}

@Serializable
data class RecordingStartResponse(
    val success: Boolean,
    @SerialName("recording_id") val recordingId: String
)
```

---

### 5.3 Step 3 — Retrain the Adaptive Classifier

Once all 4 `train_*` recordings exist, trigger retraining. It completes in seconds.

```
POST /api/v1/adaptive/train   → triggers retraining from all train_* recordings
GET  /api/v1/adaptive/status  → check new accuracy
```

**Response (success):**
```json
{ "success": true, "trained_frames": 3316, "accuracy": 0.72 }
```

**Response (no data):**
```json
{ "success": false, "error": "No training samples found. Record data with train_* prefix." }
```

**Swift:**

```swift
func retrainClassifier() async throws -> AdaptiveStatus {
    let trainURL = URL(string: "http://\(host):3022/api/v1/adaptive/train")!
    var req = URLRequest(url: trainURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = "{}".data(using: .utf8)
    let (data, _) = try await URLSession.shared.data(for: req)
    let result = try JSONDecoder().decode(TrainResult.self, from: data)
    guard result.success else { throw RuViewError.trainingFailed(result.error ?? "Unknown error") }

    // Fetch updated status
    let statusURL = URL(string: "http://\(host):3022/api/v1/adaptive/status")!
    let (statusData, _) = try await URLSession.shared.data(from: statusURL)
    return try JSONDecoder().decode(AdaptiveStatus.self, from: statusData)
}

struct TrainResult: Decodable {
    let success: Bool
    let error: String?
}

struct AdaptiveStatus: Decodable {
    let loaded: Bool
    let accuracy: Double?
    let trainedFrames: Int?
    let classes: [String]?
    enum CodingKeys: String, CodingKey {
        case loaded, accuracy, classes
        case trainedFrames = "trained_frames"
    }
}
```

**Accuracy interpretation:**

| Accuracy | Meaning |
|----------|---------|
| < 0.5 | Poor — re-record training data, more diverse scenarios |
| 0.5 – 0.7 | Acceptable — works for basic occupancy |
| > 0.7 | Good — reliable for production use |

---

### 5.4 Step 4 — Tune the Dedup Factor

After training, the person count may still be off because the dedup factor needs adjusting for your node count and room geometry. Use the ground-truth endpoint to auto-fix it.

**How it works:** Stand in the room with a known number of people, then call:

```
POST /api/v1/config/ground-truth   body: {"count": 2}
```

The server observes the current raw node sum and computes the correct factor automatically.

```json
{ "status": "ok", "ground_truth": 2, "raw_sum": 6, "computed_dedup_factor": 3.0 }
```

**Swift:**

```swift
func setGroundTruth(_ personCount: Int) async throws -> Double {
    let url = URL(string: "http://\(host):3022/api/v1/config/ground-truth")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["count": personCount])
    let (data, _) = try await URLSession.shared.data(for: req)
    let res = try JSONDecoder().decode(GroundTruthResponse.self, from: data)
    return res.computedDedupFactor
}

struct GroundTruthResponse: Decodable {
    let status: String
    let groundTruth: Int
    let rawSum: Int
    let computedDedupFactor: Double
    enum CodingKeys: String, CodingKey {
        case status
        case groundTruth = "ground_truth"
        case rawSum = "raw_sum"
        case computedDedupFactor = "computed_dedup_factor"
    }
}
```

---

### 5.5 Building a Training Flow in Your App

The full training wizard is a 4-step onboarding flow, ideally shown once during initial device setup:

```
Step 1: Empty-room calibration
  ┌─────────────────────────────────┐
  │  Please clear the room          │
  │  Collecting baseline...         │
  │  ████████░░░░░░░░  4200/12000  │
  │  Estimated: 13 min remaining    │
  └─────────────────────────────────┘

Step 2: Record each class (×4)
  ┌─────────────────────────────────┐
  │  Now: stand still in the room   │
  │  Recording "train_present_still"│
  │  ████████████████░░  54s / 60s  │
  └─────────────────────────────────┘

Step 3: Train
  ┌─────────────────────────────────┐
  │  Training classifier...         │
  │  ✓ Done — Accuracy: 72%        │
  └─────────────────────────────────┘

Step 4: Calibrate count
  ┌─────────────────────────────────┐
  │  How many people are in the     │
  │  room right now?   [ 2 ] ±      │
  │  [ Apply ]                      │
  └─────────────────────────────────┘
```

**Orchestrating the full flow (Swift):**

```swift
class TrainingOrchestrator {
    let host: String
    let calibrationManager: CalibrationManager
    var onStepChange: ((TrainingStep) -> Void)?

    enum TrainingStep {
        case calibrating(progress: Double)  // 0.0–1.0
        case recording(label: String, progress: Double)
        case training
        case countCalibration
        case complete(accuracy: Double)
        case failed(String)
    }

    private let labels = ["absent", "present_still", "present_moving", "active"]
    private let recordingDuration: Int = 60

    func run() async {
        // Step 1: Empty-room calibration
        await runCalibration()

        // Step 2: Record each label
        for label in labels {
            onStepChange?(.recording(label: label, progress: 0))
            do {
                _ = try await recordLabel(label, durationSeconds: recordingDuration)
            } catch {
                onStepChange?(.failed("Recording failed for \(label): \(error.localizedDescription)"))
                return
            }
        }

        // Step 3: Retrain
        onStepChange?(.training)
        do {
            let status = try await retrainClassifier()
            let accuracy = status.accuracy ?? 0
            // Step 4: Count calibration (UI prompts user for ground truth)
            onStepChange?(.countCalibration)
            // App presents stepper — user calls setGroundTruth()
            // then:
            onStepChange?(.complete(accuracy: accuracy))
        } catch {
            onStepChange?(.failed(error.localizedDescription))
        }
    }

    private func runCalibration() async {
        await calibrationManager.startCalibration()
        // Poll until done — CalibrationManager calls onProgress/onComplete
        while !calibrationManager.isDone { await Task.yield() }
    }
}
```

**Re-training triggers:** You don't need to run the full wizard every time. Re-run only what changed:

| Scenario | What to redo |
|----------|-------------|
| Moved furniture | Steps 1 + 2 + 3 |
| Added/moved a node | Steps 1 + 2 + 3 + 4 |
| Accuracy degraded over time | Steps 2 + 3 |
| Person count wrong | Step 4 only |
| Moved to a new room | Full wizard |

---

---

## 6. Data Interpretation Guide

### Person Count (`estimated_persons`)

The server fuses all 4 node counts using a dedup factor (currently `3.0`). Each node independently detects people in its coverage area, so the same person is counted multiple times before dedup.

- **If the count seems too high:** `POST /api/v1/config/ground-truth` with the actual count — the server will auto-adjust the dedup factor.
- **Normal range for this 4-node setup:** 0–8 persons.

### Motion Level

| Value | Meaning | Typical scenario |
|-------|---------|-----------------|
| `"absent"` | No one detected | Empty room |
| `"present_still"` | Person(s) present, not moving | Someone sitting/sleeping |
| `"present_moving"` | Active walking/movement | Normal activity |
| `"active"` | High activity | Multiple people, rapid movement |

The classification `confidence` is 0–1. Below `0.4`, treat it as uncertain and show the previous state or a neutral indicator.

### Vital Signs

- **Heart rate range:** 50–120 bpm is physiologically normal. Values outside this are likely noise.
- **Breathing rate range:** 8–25 rpm is normal. Values outside this range are noise.
- **`signal_quality`** is currently fixed at `0.5` — don't use it for filtering yet.
- **Low confidence (< 0.3):** The buffer hasn't accumulated enough CSI cycles. Show "Measuring…" for the first ~30 seconds after connecting.
- **Vital signs reflect the nearest person** to the dominant node — in a multi-person room, they're not per-person.

### Keypoints

- All keypoints are always present (all 17), even when confidence is `0.0`.
- Positions are valid even at `confidence: 0.0` for WiFi-only sensing — the `z` depth coordinate adds the third dimension.
- `z` is signed: negative means the person is on the sensor side of the reference plane.
- `bbox` x/y is the top-left corner; width/height are in the same 640×480 pixel space.

### `tick`

Increments every 100ms from server start. Use it to detect stale WebSocket frames:

```swift
var lastTick: Int = 0
var isStale: Bool { tick == lastTick }  // stale if tick stopped advancing
```

### `source`

| Value | Meaning |
|-------|---------|
| `"esp32"` | Real hardware — data is live |
| `"simulate"` | No ESP32 connected — synthetic data for testing |
| `"file"` | Replaying a recording |

Always surface `source` to the user. A `"simulate"` device should show a clear "Demo mode" indicator.

---

## 7. Connection Management

Both iOS and Android should implement:

1. **Exponential backoff reconnect** — don't hammer a temporarily unreachable device
2. **Foreground/background handling** — disconnect WebSocket when app backgrounds, reconnect on foreground
3. **Health check before WebSocket** — if `/health` returns an error, show a "Device offline" screen before attempting WS

**Swift — reconnect with backoff:**

```swift
class RuViewClient {
    private var retryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 30.0

    private func scheduleReconnect(host: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.retryDelay = min(self.retryDelay * 2, self.maxRetryDelay)
            self.connect(host: host)
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.retryDelay = 1.0  // reset on success
                // ... handle message
                self?.receiveLoop()
            case .failure:
                self?.onConnectionChange?(false)
                self?.scheduleReconnect(host: self?.currentHost ?? "")
            }
        }
    }
}
```

**Kotlin — reconnect with backoff:**

```kotlin
class RuViewClient {
    private var retryDelayMs = 1_000L
    private val maxRetryDelayMs = 30_000L
    private var currentHost = ""
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private fun scheduleReconnect() {
        scope.launch {
            delay(retryDelayMs)
            retryDelayMs = minOf(retryDelayMs * 2, maxRetryDelayMs)
            connect(currentHost)
        }
    }

    fun connect(host: String) {
        currentHost = host
        // ... same as before, call scheduleReconnect() in onFailure/onClosed
    }
}
```

**Background handling (iOS):**

```swift
// In SceneDelegate or AppDelegate
func sceneDidEnterBackground(_ scene: UIScene) {
    RuViewClient.shared.disconnect()
}

func sceneWillEnterForeground(_ scene: UIScene) {
    RuViewClient.shared.connect(host: savedHost)
}
```

---

## 8. Handling Offline & Stale Data

### Device unreachable

Before showing the main screen, call `GET /health` with a short timeout:

```swift
func checkDevice(host: String) async -> DeviceState {
    guard let url = URL(string: "http://\(host):3022/health") else { return .invalidURL }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3.0
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        return health.source == "esp32" ? .liveHardware : .simulationMode
    } catch {
        return .offline
    }
}

enum DeviceState {
    case liveHardware    // show full UI
    case simulationMode  // show "Demo" banner
    case offline         // show "Device not found" screen with retry
    case invalidURL
}
```

### Data goes stale mid-session

If the WebSocket is open but `tick` stops advancing, the server is frozen or the stream is paused:

```swift
private var lastTick = 0
private var staleness = 0

func onMessage(_ snapshot: SensingSnapshot) {
    if snapshot.tick == lastTick {
        staleness += 1
        if staleness > 5 { showStaleBanner() }
    } else {
        staleness = 0
        hideStaleBanner()
    }
    lastTick = snapshot.tick
}
```

### No persons detected but room is occupied

If `estimated_persons` is 0 but you know people are present:

1. Check `classification.motion_level` — if it's `"present_still"` or `"present_moving"`, the sensor detects activity but person-count dedup may be too aggressive. Try `POST /api/v1/config/ground-truth` with the actual count.
2. Check `GET /api/v1/nodes` — if `last_seen_ms > 500` for all nodes, the ESP32s may have lost connection.
3. Check `GET /api/v1/calibration/status` — if calibration was never run, baseline accuracy is lower.

---

## Quick Decision Guide

| What you want to build | Primary endpoint | Update rate |
|------------------------|-----------------|-------------|
| Live person count | WebSocket `estimated_persons` | 10 Hz |
| Motion state badge | WebSocket `classification.motion_level` | 10 Hz |
| Heart rate / breathing | WebSocket `vital_signs` | 10 Hz |
| Skeleton animation | WebSocket `persons[].keypoints` | 10 Hz |
| Node status indicators | `GET /api/v1/nodes` | Every 5s |
| Zone floor plan | `GET /api/v1/pose/zones/summary` | Every 2s |
| Recording controls | `POST /api/v1/recording/start|stop` | On demand |
| Dedup calibration | `POST /api/v1/config/ground-truth` | On demand |
| App launch health check | `GET /health` | Once |
| Device info / version | `GET /api/v1/info` | Once |
