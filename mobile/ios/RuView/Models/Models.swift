import Foundation

// MARK: - Top-level snapshot

struct SensingSnapshot: Decodable {
    let source: String
    let tick: Int
    let timestamp: Double
    let type: String
    let estimatedPersons: Int?
    let classification: Classification
    let nodeFeatures: [NodeFeature]?
    let nodes: [NodeInfo]?
    let persons: [Person]?
    let vitalSigns: VitalSigns?
    let signalField: SignalField?

    enum CodingKeys: String, CodingKey {
        case source, tick, timestamp, type
        case estimatedPersons = "estimated_persons"
        case classification
        case nodeFeatures = "node_features"
        case nodes, persons
        case vitalSigns = "vital_signs"
        case signalField = "signal_field"
    }
}

// MARK: - Classification

struct Classification: Decodable {
    let presence: Bool
    let motionLevel: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case presence
        case motionLevel = "motion_level"
        case confidence
    }
}

// MARK: - Vital Signs

struct VitalSigns: Decodable {
    // Server sends null for HR/BR when no person is being tracked.
    let heartRateBpm: Double?
    let breathingRateBpm: Double?
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

// MARK: - Person

struct Person: Decodable, Identifiable {
    let id: Int
    let pose: String
    let confidence: Double
    let facing: Double
    let motionScore: Double
    let zone: String
    let position: [Double]
    let bbox: BoundingBox
    let keypoints: [Keypoint]

    enum CodingKeys: String, CodingKey {
        case id, pose, confidence, facing
        case motionScore = "motion_score"
        case zone, position, bbox, keypoints
    }
}

// MARK: - Keypoint

struct Keypoint: Decodable {
    let name: String
    let x: Double
    let y: Double
    let z: Double
    let confidence: Double
}

// MARK: - BoundingBox

struct BoundingBox: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// MARK: - NodeFeature

struct NodeFeature: Decodable, Identifiable {
    let nodeId: Int
    let rssiDbm: Double
    let lastSeenMs: Int
    let stale: Bool
    let classification: Classification

    var id: Int { nodeId }

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case rssiDbm = "rssi_dbm"
        case lastSeenMs = "last_seen_ms"
        case stale, classification
    }
}

// MARK: - NodeInfo

struct NodeInfo: Decodable, Identifiable {
    let nodeId: Int
    let rssiDbm: Double
    let subcarrierCount: Int
    let position: [Double]
    let amplitude: [Double]

    var id: Int { nodeId }

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case rssiDbm = "rssi_dbm"
        case subcarrierCount = "subcarrier_count"
        case position, amplitude
    }
}

// MARK: - SignalField

struct SignalField: Decodable {
    let gridSize: [Int]
    let values: [Double]

    enum CodingKeys: String, CodingKey {
        case gridSize = "grid_size"
        case values
    }
}

// MARK: - REST response types

struct HealthResponse: Decodable {
    let status: String
    let source: String
    let tick: Int
    let clients: Int
}

struct NodesResponse: Decodable {
    let total: Int
    let nodes: [NodeStatus]
}

struct NodeStatus: Decodable, Identifiable {
    let nodeId: Int
    let status: String
    let rssiDbm: Double
    let lastSeenMs: Int
    let motionLevel: String
    let personCount: Int
    let radarType: String

    var id: Int { nodeId }

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case status
        case rssiDbm = "rssi_dbm"
        case lastSeenMs = "last_seen_ms"
        case motionLevel = "motion_level"
        case personCount = "person_count"
        case radarType = "radar_type"
    }
}

struct ZoneInfo: Identifiable {
    let name: String
    let personCount: Int
    let status: String

    var id: String { name }
}

struct ZoneSummaryResponse: Decodable {
    let zones: [String: ZoneData]
}

struct ZoneData: Decodable {
    let personCount: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case personCount = "person_count"
        case status
    }
}

struct VitalSignsResponse: Decodable {
    let vitalSigns: VitalSigns

    enum CodingKeys: String, CodingKey {
        case vitalSigns = "vital_signs"
    }
}

struct AdaptiveStatus: Decodable {
    let loaded: Bool
    let accuracy: Double?
    let trainedFrames: Int?
    let classes: [String]?

    enum CodingKeys: String, CodingKey {
        case loaded, accuracy
        case trainedFrames = "trained_frames"
        case classes
    }
}

struct CalibrationStatus: Decodable {
    let active: Bool
    let status: String
    let frames: Int?
    let target: Int?
}

struct BoolResponse: Decodable {
    let success: Bool
    let error: String?
    let recordingId: String?
    let accuracy: Double?
    let computedDedupFactor: Double?

    enum CodingKeys: String, CodingKey {
        case success, error, accuracy
        case recordingId = "recording_id"
        case computedDedupFactor = "computed_dedup_factor"
    }
}

// MARK: - COCO-17 Skeleton edges

enum SkeletonEdge {
    static let keypointNames: [String] = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle"
    ]

    // Each pair is (from, to) using keypoint names
    static let edges: [(String, String)] = [
        ("nose", "left_eye"),
        ("nose", "right_eye"),
        ("left_eye", "left_ear"),
        ("right_eye", "right_ear"),
        ("left_ear", "left_shoulder"),
        ("right_ear", "right_shoulder"),
        ("left_shoulder", "right_shoulder"),
        ("left_shoulder", "left_elbow"),
        ("right_shoulder", "right_elbow"),
        ("left_elbow", "left_wrist"),
        ("right_elbow", "right_wrist"),
        ("left_shoulder", "left_hip"),
        ("right_shoulder", "right_hip"),
        ("left_hip", "right_hip"),
        ("left_hip", "left_knee"),
        ("right_hip", "right_knee"),
        ("left_knee", "left_ankle"),
        ("right_knee", "right_ankle")
    ]
}

// MARK: - Motion level helpers

extension String {
    var motionLevelDisplay: String {
        switch self {
        case "absent": return "Empty"
        case "present_still": return "Someone here"
        case "present_moving": return "Movement detected"
        case "active": return "High activity"
        default: return self.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Server status / trust engine — GET /api/v1/status
// Upstream (post-sync) exposes the sensing trust engine: whether the server has
// demoted its own outputs, suppressed raw values, hit engine errors, or wants a
// recalibration. Surfaced in Node Health as a reliability indicator (all use cases).

struct ServerStatus: Decodable {
    let status: String
    let trust: TrustState
}

struct TrustState: Decodable {
    let demoted: Bool
    let engineErrorCount: Int
    let rawOutputsSuppressed: Bool
    let recalibrationRecommended: Bool

    enum CodingKeys: String, CodingKey {
        case demoted
        case engineErrorCount = "engine_error_count"
        case rawOutputsSuppressed = "raw_outputs_suppressed"
        case recalibrationRecommended = "recalibration_recommended"
    }

    enum Level { case trusted, caution, degraded }

    var level: Level {
        if demoted || rawOutputsSuppressed { return .degraded }
        if recalibrationRecommended || engineErrorCount > 0 { return .caution }
        return .trusted
    }

    var summary: String {
        switch level {
        case .trusted:
            return "Trusted"
        case .caution:
            return recalibrationRecommended
                ? "Recalibration recommended"
                : "\(engineErrorCount) engine warning\(engineErrorCount == 1 ? "" : "s")"
        case .degraded:
            return demoted ? "Sensing demoted" : "Raw outputs suppressed"
        }
    }
}

// MARK: - System metrics (Pi health) — GET /api/v1/metrics

struct SystemMetricsResponse: Decodable {
    let systemMetrics: SystemMetrics

    enum CodingKeys: String, CodingKey {
        case systemMetrics = "system_metrics"
    }
}

struct SystemMetrics: Decodable {
    let cpu: MetricPercent
    let memory: MetricPercent
    let disk: MetricPercent
}

struct MetricPercent: Decodable {
    let percent: Double
    let usedMb: Int?

    enum CodingKeys: String, CodingKey {
        case percent
        case usedMb = "used_mb"
    }
}
