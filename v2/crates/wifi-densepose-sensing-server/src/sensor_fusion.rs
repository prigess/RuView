//! Sensor Fusion Module for RuView
//!
//! Combines CSI data with radar sensors (LD2410C, MR60BHA2) for improved accuracy.
//! This module provides:
//! - Multi-sensor person counting with confidence weighting
//! - Radar-assisted presence validation
//! - Temporal tracking for stable counts
//! - Alert generation for healthcare applications

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

// ── Radar Types ────────────────────────────────────────────────────────────────

/// Radar sensor types supported
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RadarType {
    None = 0,
    MR60BHA2 = 1,  // 60 GHz FMCW - vital signs
    LD2410 = 2,    // 24 GHz FMCW - presence + distance
}

impl From<u8> for RadarType {
    fn from(v: u8) -> Self {
        match v {
            1 => RadarType::MR60BHA2,
            2 => RadarType::LD2410,
            _ => RadarType::None,
        }
    }
}

/// Radar sensor reading
#[derive(Debug, Clone)]
pub struct RadarReading {
    pub radar_type: RadarType,
    pub targets: u8,
    pub distance_cm: u16,
    pub presence: bool,
    pub motion_energy: f32,
    pub timestamp: Instant,
}

// ── Fused Person Estimate ──────────────────────────────────────────────────────

/// Fused estimate combining CSI and radar data
#[derive(Debug, Clone)]
pub struct FusedPersonEstimate {
    /// Estimated person count (0-5)
    pub count: usize,
    /// Confidence in the count [0.0, 1.0]
    pub confidence: f64,
    /// Source breakdown for debugging
    pub source_breakdown: SourceBreakdown,
    /// Stability score (higher = more stable over time)
    pub stability: f64,
    /// Time since last change
    pub last_change: Option<Instant>,
}

#[derive(Debug, Clone, Default)]
pub struct SourceBreakdown {
    pub csi_count: usize,
    pub csi_confidence: f64,
    pub radar_count: usize,
    pub radar_confidence: f64,
    pub nodes_active: usize,
    pub radar_sensors_active: usize,
}

// ── Sensor Fusion Engine ───────────────────────────────────────────────────────

/// Configuration for sensor fusion
#[derive(Debug, Clone)]
pub struct FusionConfig {
    /// Weight for CSI-based estimate [0.0, 1.0]
    pub csi_weight: f64,
    /// Weight for radar-based estimate [0.0, 1.0]
    pub radar_weight: f64,
    /// Minimum confidence to change count
    pub change_threshold: f64,
    /// Frames to hold before changing count
    pub debounce_frames: usize,
    /// Max age for radar readings (ms)
    pub radar_max_age_ms: u64,
    /// Enable temporal smoothing
    pub temporal_smoothing: bool,
}

impl Default for FusionConfig {
    fn default() -> Self {
        Self {
            csi_weight: 0.6,
            radar_weight: 0.4,
            change_threshold: 0.7,
            debounce_frames: 5,
            radar_max_age_ms: 2000,
            temporal_smoothing: true,
        }
    }
}

/// Main sensor fusion engine
pub struct SensorFusion {
    config: FusionConfig,
    /// Per-node CSI person scores
    node_scores: HashMap<u8, VecDeque<f64>>,
    /// Per-node radar readings
    radar_readings: HashMap<u8, RadarReading>,
    /// Count history for temporal smoothing
    count_history: VecDeque<usize>,
    /// Current fused estimate
    current_estimate: FusedPersonEstimate,
    /// Debounce state
    debounce_count: usize,
    debounce_candidate: usize,
}

impl SensorFusion {
    pub fn new(config: FusionConfig) -> Self {
        Self {
            config,
            node_scores: HashMap::new(),
            radar_readings: HashMap::new(),
            count_history: VecDeque::with_capacity(30),
            current_estimate: FusedPersonEstimate {
                count: 0,
                confidence: 0.0,
                source_breakdown: SourceBreakdown::default(),
                stability: 0.0,
                last_change: None,
            },
            debounce_count: 0,
            debounce_candidate: 0,
        }
    }

    /// Update CSI-based person score for a node
    pub fn update_csi_score(&mut self, node_id: u8, score: f64) {
        let scores = self.node_scores.entry(node_id).or_insert_with(|| VecDeque::with_capacity(20));
        scores.push_back(score);
        if scores.len() > 20 {
            scores.pop_front();
        }
    }

    /// Update radar reading for a node
    pub fn update_radar(&mut self, node_id: u8, reading: RadarReading) {
        self.radar_readings.insert(node_id, reading);
    }

    /// Get the fused person count estimate
    pub fn estimate(&mut self) -> FusedPersonEstimate {
        let now = Instant::now();

        // Collect CSI estimates from all nodes
        let (csi_count, csi_conf) = self.estimate_from_csi();

        // Collect radar estimates
        let (radar_count, radar_conf) = self.estimate_from_radar(now);

        // Weighted fusion
        let total_weight = if radar_conf > 0.1 {
            self.config.csi_weight + self.config.radar_weight
        } else {
            self.config.csi_weight // Only CSI if no radar
        };

        let fused_score = if radar_conf > 0.1 {
            (csi_count as f64 * csi_conf * self.config.csi_weight
                + radar_count as f64 * radar_conf * self.config.radar_weight)
                / total_weight
        } else {
            csi_count as f64 * csi_conf
        };

        let fused_count = fused_score.round() as usize;
        let fused_conf = if radar_conf > 0.1 {
            (csi_conf * self.config.csi_weight + radar_conf * self.config.radar_weight) / total_weight
        } else {
            csi_conf * 0.8 // Lower confidence without radar
        };

        // Debounce: require consistent readings before changing
        let final_count = self.apply_debounce(fused_count, fused_conf);

        // Update history for stability calculation
        self.count_history.push_back(final_count);
        if self.count_history.len() > 30 {
            self.count_history.pop_front();
        }

        let stability = self.calculate_stability();

        // Update last_change if count changed
        let last_change = if final_count != self.current_estimate.count {
            Some(now)
        } else {
            self.current_estimate.last_change
        };

        self.current_estimate = FusedPersonEstimate {
            count: final_count,
            confidence: fused_conf,
            source_breakdown: SourceBreakdown {
                csi_count,
                csi_confidence: csi_conf,
                radar_count,
                radar_confidence: radar_conf,
                nodes_active: self.node_scores.len(),
                radar_sensors_active: self.radar_readings.iter()
                    .filter(|(_, r)| now.duration_since(r.timestamp) < Duration::from_millis(self.config.radar_max_age_ms))
                    .count(),
            },
            stability,
            last_change,
        };

        self.current_estimate.clone()
    }

    fn estimate_from_csi(&self) -> (usize, f64) {
        if self.node_scores.is_empty() {
            return (0, 0.0);
        }

        // Get recent average score from each node
        let node_avgs: Vec<f64> = self.node_scores
            .values()
            .filter_map(|scores| {
                if scores.is_empty() {
                    return None;
                }
                let recent: Vec<f64> = scores.iter().rev().take(5).copied().collect();
                Some(recent.iter().sum::<f64>() / recent.len() as f64)
            })
            .collect();

        if node_avgs.is_empty() {
            return (0, 0.0);
        }

        // Take max score (not sum) to avoid over-counting same person
        // Multiple nodes seeing same person should converge, not multiply
        let max_score = node_avgs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

        // Also check variance across nodes - low variance = same person
        let mean_score = node_avgs.iter().sum::<f64>() / node_avgs.len() as f64;
        let variance = node_avgs.iter().map(|s| (s - mean_score).powi(2)).sum::<f64>() / node_avgs.len() as f64;

        // High variance suggests different views (maybe different people)
        let diversity_factor = if variance > 0.1 { 1.2 } else { 1.0 };

        // Convert score to count with tuned thresholds
        // Score 0.0-0.1 = absent, 0.1-0.4 = 1 person, 0.4-0.7 = 2, 0.7+ = 3
        let count = if max_score < 0.10 {
            0
        } else if max_score < 0.40 {
            1
        } else if max_score < 0.70 {
            2
        } else {
            ((max_score - 0.40) / 0.20 * diversity_factor + 1.5).round().min(5.0) as usize
        };

        // Confidence based on score strength and node agreement
        let agreement = 1.0 - (variance / (mean_score.powi(2) + 0.01)).sqrt().min(1.0);
        let confidence = (max_score * 0.6 + agreement * 0.4).clamp(0.0, 1.0);

        (count, confidence)
    }

    fn estimate_from_radar(&self, now: Instant) -> (usize, f64) {
        let max_age = Duration::from_millis(self.config.radar_max_age_ms);

        let active_radars: Vec<&RadarReading> = self.radar_readings
            .values()
            .filter(|r| now.duration_since(r.timestamp) < max_age)
            .collect();

        if active_radars.is_empty() {
            return (0, 0.0);
        }

        // LD2410 provides direct target count
        let mut total_targets = 0usize;
        let mut presence_votes = 0usize;
        let mut confidence_sum = 0.0f64;

        for radar in &active_radars {
            if radar.presence {
                presence_votes += 1;
            }

            match radar.radar_type {
                RadarType::LD2410 => {
                    // LD2410 gives target count directly
                    total_targets = total_targets.max(radar.targets as usize);
                    // Confidence based on signal strength
                    let dist_conf = if radar.distance_cm > 0 && radar.distance_cm < 500 {
                        1.0 - (radar.distance_cm as f64 / 500.0) * 0.3
                    } else {
                        0.5
                    };
                    confidence_sum += dist_conf;
                }
                RadarType::MR60BHA2 => {
                    // MR60BHA2 for vital signs - presence only
                    if radar.presence {
                        total_targets = total_targets.max(1);
                    }
                    confidence_sum += 0.8;
                }
                RadarType::None => {}
            }
        }

        // If any radar detects presence but count is 0, set to 1
        if presence_votes > 0 && total_targets == 0 {
            total_targets = 1;
        }

        let confidence = if active_radars.is_empty() {
            0.0
        } else {
            (confidence_sum / active_radars.len() as f64).clamp(0.0, 1.0)
        };

        (total_targets, confidence)
    }

    fn apply_debounce(&mut self, candidate: usize, confidence: f64) -> usize {
        if confidence < self.config.change_threshold {
            // Low confidence - keep current
            return self.current_estimate.count;
        }

        if candidate == self.current_estimate.count {
            // Same count - reset debounce
            self.debounce_count = 0;
            self.debounce_candidate = candidate;
            return candidate;
        }

        if candidate == self.debounce_candidate {
            // Same candidate - increment counter
            self.debounce_count += 1;
        } else {
            // New candidate - reset
            self.debounce_candidate = candidate;
            self.debounce_count = 1;
        }

        // Check if threshold reached
        if self.debounce_count >= self.config.debounce_frames {
            // Threshold reached - accept new count
            self.debounce_count = 0;
            return candidate;
        }

        // Not yet accepted - keep current
        self.current_estimate.count
    }

    fn calculate_stability(&self) -> f64 {
        if self.count_history.len() < 5 {
            return 0.5;
        }

        let recent: Vec<usize> = self.count_history.iter().rev().take(10).copied().collect();
        let mean = recent.iter().sum::<usize>() as f64 / recent.len() as f64;
        let variance = recent.iter().map(|&c| (c as f64 - mean).powi(2)).sum::<f64>() / recent.len() as f64;

        // Low variance = high stability
        (1.0 - variance.sqrt() / 2.0).clamp(0.0, 1.0)
    }

    /// Get current estimate without updating
    pub fn current(&self) -> &FusedPersonEstimate {
        &self.current_estimate
    }
}

// ── Healthcare Alerts ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum AlertLevel {
    Info,
    Warning,
    Critical,
}

#[derive(Debug, Clone)]
pub struct HealthcareAlert {
    pub level: AlertLevel,
    pub alert_type: String,
    pub message: String,
    pub timestamp: Instant,
    pub data: serde_json::Value,
}

/// Healthcare alert generator based on sensing data
pub struct AlertGenerator {
    /// Last motion detected timestamp
    last_motion: Option<Instant>,
    /// No-motion threshold for alerts (seconds)
    no_motion_threshold_secs: u64,
    /// Previous presence state
    prev_presence: bool,
    /// Motion history for pattern detection
    motion_history: VecDeque<(Instant, String)>,
}

impl AlertGenerator {
    pub fn new(no_motion_threshold_secs: u64) -> Self {
        Self {
            last_motion: None,
            no_motion_threshold_secs,
            prev_presence: false,
            motion_history: VecDeque::with_capacity(100),
        }
    }

    /// Check for alerts based on current sensing state
    pub fn check(&mut self, presence: bool, motion_level: &str, breathing_rate: Option<f64>) -> Vec<HealthcareAlert> {
        let now = Instant::now();
        let mut alerts = Vec::new();

        // Track motion
        if motion_level == "active" || motion_level == "present_moving" {
            self.last_motion = Some(now);
        }
        self.motion_history.push_back((now, motion_level.to_string()));
        while self.motion_history.len() > 100 {
            self.motion_history.pop_front();
        }

        // Alert 1: No motion for extended period (when person is present)
        if presence {
            if let Some(last) = self.last_motion {
                let secs_since_motion = now.duration_since(last).as_secs();
                if secs_since_motion > self.no_motion_threshold_secs {
                    alerts.push(HealthcareAlert {
                        level: AlertLevel::Warning,
                        alert_type: "NO_MOTION".to_string(),
                        message: format!("No motion detected for {} seconds", secs_since_motion),
                        timestamp: now,
                        data: serde_json::json!({
                            "seconds_since_motion": secs_since_motion,
                            "threshold": self.no_motion_threshold_secs,
                        }),
                    });
                }
            }
        }

        // Alert 2: Sudden absence after presence (possible fall)
        if self.prev_presence && !presence {
            // Check if there was recent active motion before absence
            let recent_active = self.motion_history.iter()
                .rev()
                .take(10)
                .any(|(_, m)| m == "active");

            if recent_active {
                alerts.push(HealthcareAlert {
                    level: AlertLevel::Critical,
                    alert_type: "SUDDEN_ABSENCE".to_string(),
                    message: "Sudden absence detected after active movement - possible fall".to_string(),
                    timestamp: now,
                    data: serde_json::json!({
                        "prev_presence": true,
                        "current_presence": false,
                        "recent_motion_level": motion_level,
                    }),
                });
            }
        }

        // Alert 3: Abnormal breathing rate
        if let Some(br) = breathing_rate {
            if br < 8.0 {
                alerts.push(HealthcareAlert {
                    level: AlertLevel::Critical,
                    alert_type: "LOW_BREATHING_RATE".to_string(),
                    message: format!("Low breathing rate detected: {:.1} bpm", br),
                    timestamp: now,
                    data: serde_json::json!({
                        "breathing_rate": br,
                        "threshold": 8.0,
                    }),
                });
            } else if br > 30.0 {
                alerts.push(HealthcareAlert {
                    level: AlertLevel::Warning,
                    alert_type: "HIGH_BREATHING_RATE".to_string(),
                    message: format!("High breathing rate detected: {:.1} bpm", br),
                    timestamp: now,
                    data: serde_json::json!({
                        "breathing_rate": br,
                        "threshold": 30.0,
                    }),
                });
            }
        }

        self.prev_presence = presence;
        alerts
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sensor_fusion_csi_only() {
        let mut fusion = SensorFusion::new(FusionConfig {
            debounce_frames: 1, // Lower for testing
            change_threshold: 0.3,
            ..Default::default()
        });

        // Simulate one person detected by 3 nodes with multiple readings
        for _ in 0..5 {
            fusion.update_csi_score(1, 0.5);
            fusion.update_csi_score(2, 0.48);
            fusion.update_csi_score(3, 0.52);
        }

        let estimate = fusion.estimate();
        assert!(estimate.count >= 1 && estimate.count <= 2, "Expected 1-2 persons, got {}", estimate.count);
        assert!(estimate.confidence > 0.3, "Expected confidence > 0.3, got {}", estimate.confidence);
    }

    #[test]
    fn test_sensor_fusion_with_radar() {
        let mut fusion = SensorFusion::new(FusionConfig {
            debounce_frames: 1,
            change_threshold: 0.3,
            ..Default::default()
        });

        // CSI suggests presence with multiple readings
        for _ in 0..5 {
            fusion.update_csi_score(1, 0.4);
        }

        // Radar confirms 1 person at 2m
        fusion.update_radar(1, RadarReading {
            radar_type: RadarType::LD2410,
            targets: 1,
            distance_cm: 200,
            presence: true,
            motion_energy: 0.5,
            timestamp: Instant::now(),
        });

        let estimate = fusion.estimate();
        assert!(estimate.count >= 1, "Expected at least 1 person with radar confirmation, got {}", estimate.count);
        assert!(estimate.source_breakdown.radar_sensors_active > 0, "Expected active radar sensor");
    }

    #[test]
    fn test_debounce_prevents_flicker() {
        let config = FusionConfig {
            debounce_frames: 3,
            ..Default::default()
        };
        let mut fusion = SensorFusion::new(config);

        // Establish baseline
        for _ in 0..5 {
            fusion.update_csi_score(1, 0.5);
            fusion.estimate();
        }

        // Single spike shouldn't change count immediately
        fusion.update_csi_score(1, 0.9);
        let e1 = fusion.estimate();

        fusion.update_csi_score(1, 0.5);
        let e2 = fusion.estimate();

        // Count should remain stable
        assert_eq!(e1.count, e2.count, "Count should not flicker on single spike");
    }

    #[test]
    fn test_alert_no_motion() {
        let mut gen = AlertGenerator::new(30);

        // Initial motion
        let alerts = gen.check(true, "active", Some(14.0));
        assert!(alerts.is_empty());

        // Simulate 35 seconds of stillness
        std::thread::sleep(std::time::Duration::from_millis(50));
        gen.last_motion = Some(Instant::now() - std::time::Duration::from_secs(35));

        let alerts = gen.check(true, "present_still", Some(14.0));
        assert!(!alerts.is_empty(), "Should generate no-motion alert");
        assert_eq!(alerts[0].alert_type, "NO_MOTION");
    }

    #[test]
    fn test_alert_low_breathing() {
        let mut gen = AlertGenerator::new(60);

        let alerts = gen.check(true, "present_still", Some(6.0));
        assert!(!alerts.is_empty());
        assert_eq!(alerts[0].alert_type, "LOW_BREATHING_RATE");
        assert_eq!(alerts[0].level, AlertLevel::Critical);
    }
}
