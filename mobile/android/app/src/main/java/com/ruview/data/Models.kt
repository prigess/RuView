package com.ruview.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SensingSnapshot(
    val source: String = "unknown",
    val tick: Long = 0L,
    val timestamp: Double = 0.0,
    val type: String = "",
    @SerialName("estimated_persons") val estimatedPersons: Int = 0,
    val classification: Classification = Classification(),
    @SerialName("node_features") val nodeFeatures: List<NodeFeature> = emptyList(),
    val nodes: List<NodeInfo> = emptyList(),
    val persons: List<Person> = emptyList(),
    @SerialName("vital_signs") val vitalSigns: VitalSigns? = null
)

@Serializable
data class Classification(
    val presence: Boolean = false,
    @SerialName("motion_level") val motionLevel: String = "absent",
    val confidence: Double = 0.0
)

@Serializable
data class VitalSigns(
    @SerialName("heart_rate_bpm") val heartRateBpm: Double = 0.0,
    @SerialName("breathing_rate_bpm") val breathingRateBpm: Double = 0.0,
    @SerialName("heartbeat_confidence") val heartbeatConfidence: Double = 0.0,
    @SerialName("breathing_confidence") val breathingConfidence: Double = 0.0,
    @SerialName("signal_quality") val signalQuality: Double = 0.0
)

@Serializable
data class Person(
    val id: Long = 0L,
    val pose: String = "",
    val confidence: Double = 0.0,
    val facing: Double = 0.0,
    @SerialName("motion_score") val motionScore: Double = 0.0,
    val zone: String = "",
    val position: List<Double> = emptyList(),
    val bbox: BoundingBox = BoundingBox(),
    val keypoints: List<Keypoint> = emptyList()
)

@Serializable
data class BoundingBox(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val width: Double = 0.0,
    val height: Double = 0.0
)

@Serializable
data class Keypoint(
    val name: String = "",
    val x: Double = 0.0,
    val y: Double = 0.0,
    val z: Double = 0.0,
    val confidence: Double = 0.0
)

@Serializable
data class NodeFeature(
    @SerialName("node_id") val nodeId: Int = 0,
    @SerialName("rssi_dbm") val rssiDbm: Double = 0.0,
    @SerialName("last_seen_ms") val lastSeenMs: Long = 0L,
    val stale: Boolean = false,
    val classification: Classification = Classification()
)

@Serializable
data class NodeInfo(
    @SerialName("node_id") val nodeId: Int = 0,
    @SerialName("rssi_dbm") val rssiDbm: Double = 0.0,
    @SerialName("subcarrier_count") val subcarrierCount: Int = 0,
    val position: List<Double> = emptyList()
)

@Serializable
data class NodeStatus(
    @SerialName("node_id") val nodeId: Int = 0,
    val status: String = "",
    @SerialName("rssi_dbm") val rssiDbm: Double = 0.0,
    @SerialName("last_seen_ms") val lastSeenMs: Long = 0L,
    @SerialName("motion_level") val motionLevel: String = "absent",
    @SerialName("person_count") val personCount: Int = 0,
    @SerialName("radar_type") val radarType: String = ""
)

@Serializable
data class NodesResponse(
    val total: Int = 0,
    val nodes: List<NodeStatus> = emptyList()
)

@Serializable
data class ZoneInfo(
    @SerialName("person_count") val personCount: Int = 0,
    val status: String = ""
)

@Serializable
data class ZoneSummary(
    val zones: Map<String, ZoneInfo> = emptyMap()
)

@Serializable
data class CalibrationStatus(
    val active: Boolean = false,
    val status: String = "",
    val frames: Int? = null,
    val target: Int? = null
)

@Serializable
data class AdaptiveStatus(
    val loaded: Boolean = false,
    val accuracy: Double? = null,
    @SerialName("trained_frames") val trainedFrames: Int? = null
)

@Serializable
data class HealthResponse(
    val status: String = "",
    val source: String = "",
    val tick: Long = 0L,
    val clients: Int = 0
)

@Serializable
data class StartCalibrationResponse(
    val success: Boolean = false
)

@Serializable
data class StopCalibrationResponse(
    val success: Boolean = false,
    val error: String? = null
)

@Serializable
data class StartRecordingRequest(
    val name: String
)

@Serializable
data class StartRecordingResponse(
    val success: Boolean = false,
    @SerialName("recording_id") val recordingId: String = ""
)

@Serializable
data class StopRecordingResponse(
    val success: Boolean = false
)

@Serializable
data class TrainRequest(
    val dummy: String = ""
)

@Serializable
data class TrainResponse(
    val success: Boolean = false,
    val accuracy: Double? = null,
    val error: String? = null
)

@Serializable
data class GroundTruthRequest(
    val count: Int
)

@Serializable
data class GroundTruthResponse(
    val status: String = "",
    @SerialName("computed_dedup_factor") val computedDedupFactor: Double = 1.0
)

// COCO-17 skeleton bone definitions
val COCO17_SKELETON_EDGES: List<Pair<String, String>> = listOf(
    "nose" to "left_eye",
    "nose" to "right_eye",
    "left_eye" to "left_ear",
    "right_eye" to "right_ear",
    "left_ear" to "left_shoulder",
    "right_ear" to "right_shoulder",
    "left_shoulder" to "right_shoulder",
    "left_shoulder" to "left_elbow",
    "right_shoulder" to "right_elbow",
    "left_elbow" to "left_wrist",
    "right_elbow" to "right_wrist",
    "left_shoulder" to "left_hip",
    "right_shoulder" to "right_hip",
    "left_hip" to "right_hip",
    "left_hip" to "left_knee",
    "right_hip" to "right_knee",
    "left_knee" to "left_ankle",
    "right_knee" to "right_ankle"
)
