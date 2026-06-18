//! C6 ESPHome radar bridge — MQTT primary, HTTP fallback.
//!
//! Source of truth for the ESP32-C6 + Seeed MR60BHA2 60 GHz radar node.
//! The ESPHome firmware (see `firmware/esphome/ruview-c6-radar.yaml`) publishes
//! sensor state to MQTT topics under a prefix; this bridge:
//!
//! 1. Subscribes to those topics and reflects each push into the shared radar
//!    state, then emits a 32-byte [`Esp32VitalsPacket`] (ADR-039 magic
//!    `0xC511_0002`) to `127.0.0.1:<udp_port>` so the existing UDP receiver
//!    decodes it without a single byte changing on the parse side.
//! 2. Falls back to HTTP polling of the ESPHome `/sensor/...` JSON endpoints
//!    whenever the MQTT topic stays silent for longer than
//!    [`C6RadarConfig::mqtt_quiet_timeout`] (5 s by default). This keeps the
//!    radar visible even if the broker, network, or YAML config is wrong.
//!
//! Why loopback-UDP rather than direct state manipulation? The existing UDP
//! path already runs ~250 lines of "decode → broadcast → store" logic that
//! ends in `s.node_states[node_id].edge_vitals = ...`. Re-using it verbatim
//! keeps the radar bridge a strictly additive change.
//!
//! Two OS threads:
//! - `c6-mqtt`: MQTT EventLoop. Push-driven, emits on each state change.
//! - `c6-http`: every 5 s; emits only if MQTT has been quiet.

use serde::Deserialize;
use std::net::UdpSocket;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tracing::{debug, info, warn};

/// Magic word of the `Esp32VitalsPacket` (ADR-039).
const VITALS_MAGIC: u32 = 0xC511_0002;

/// Radar type codes stored in byte 14 of the vitals packet. Mirrors the
/// mmwave_type_t enum in firmware/esp32-csi-node/main/mmwave_sensor.h.
pub const RADAR_TYPE_MR60BHA2: u8 = 1;
pub const RADAR_TYPE_LD2410: u8 = 2;

/// Configuration for one ESPHome radar bridge instance. The module supports
/// running multiple instances simultaneously (e.g., one for the C6/MR60BHA2,
/// one for an S3/LD2410), each with its own topic_prefix and node_id.
#[derive(Debug, Clone)]
pub struct C6RadarConfig {
    /// IP or hostname of the ESPHome device (no scheme, no port). Used as the
    /// HTTP fallback target.
    pub http_host: String,
    /// `node_id` stamped on outgoing vitals packets.
    pub node_id: u8,
    /// Radar type code stamped in byte 14 of the vitals packet
    /// (RADAR_TYPE_MR60BHA2 or RADAR_TYPE_LD2410). Determines which set of
    /// MQTT topics the subscriber recognises (HR/BR for MR60 vs.
    /// moving/still distance for LD2410).
    pub radar_type: u8,
    /// Local UDP port the sensing-server listens on; packets are sent to
    /// `127.0.0.1:<this>` so the existing receiver picks them up.
    pub udp_port: u16,
    /// MQTT broker host (e.g. `127.0.0.1` for a mosquitto on the Pi).
    /// `None` disables MQTT and forces HTTP-only operation.
    pub mqtt_host: Option<String>,
    /// MQTT broker port. Defaults to 1883 if `mqtt_host` is set.
    pub mqtt_port: u16,
    /// ESPHome MQTT `topic_prefix` (e.g. `ruview-c6-radar`).
    pub mqtt_topic_prefix: String,
    /// HTTP fallback poll interval.
    pub http_poll_interval: Duration,
    /// Per-HTTP-request timeout.
    pub http_timeout: Duration,
    /// Switch to HTTP fallback if we haven't seen an MQTT msg for this long.
    pub mqtt_quiet_timeout: Duration,
}

impl C6RadarConfig {
    pub fn http_only(http_host: String, udp_port: u16) -> Self {
        Self {
            http_host,
            node_id: 1,
            radar_type: RADAR_TYPE_MR60BHA2,
            udp_port,
            mqtt_host: None,
            mqtt_port: 1883,
            mqtt_topic_prefix: "ruview-c6-radar".into(),
            http_poll_interval: Duration::from_millis(1500),
            http_timeout: Duration::from_millis(2500),
            mqtt_quiet_timeout: Duration::from_secs(5),
        }
    }

    pub fn with_mqtt(mut self, mqtt_host: String, mqtt_port: u16, topic_prefix: String) -> Self {
        self.mqtt_host = Some(mqtt_host);
        self.mqtt_port = mqtt_port;
        self.mqtt_topic_prefix = topic_prefix;
        self
    }

    pub fn with_radar_type(mut self, radar_type: u8) -> Self {
        self.radar_type = radar_type;
        self
    }
}

/// Latest values from either MQTT or HTTP, plus the timestamp of the last
/// MQTT message seen (used to gate HTTP fallback).
#[derive(Debug, Default)]
struct RadarState {
    heart_rate_bpm: Option<f64>,
    breath_rate_bpm: Option<f64>,
    target_distance_cm: Option<u16>,
    wifi_rssi_dbm: Option<i8>,
    person_present: bool,
    // Held last-good vitals (window: ~20 s) so we keep emitting sane numbers
    // through brief drop-outs.
    held_hr: Option<f64>,
    held_br: Option<f64>,
    held_at: Option<Instant>,
    last_mqtt_seen: Option<Instant>,
    // Presence stickiness — MR60BHA2's `has_target` flag drops momentarily
    // between frames even when the person hasn't moved (the radar lost lock
    // for one cycle and re-acquires the next). Hold presence=true for
    // PRESENCE_STICKY_WINDOW after the last confirmed true reading so the
    // displayed count doesn't oscillate 1→0→1 several times a second.
    last_presence_true_at: Option<Instant>,
    // Distance-change inference (2026-06-12): the MR60BHA2's `has_target`
    // requires several seconds of stillness to lock. For walking subjects it
    // never trips — but `target_distance` updates briefly as the person
    // passes through the cone. Track the timestamp of the last non-zero
    // distance change so snapshot() can infer "transient motion" from it.
    last_distance_change_at: Option<Instant>,
    last_distance_value: Option<u16>,
    // EMA-smoothed motion energy derived from HR/BR drift between ticks.
    last_hr_seen: Option<f64>,
    last_br_seen: Option<f64>,
    motion_energy_ema: f32,
}

// Physiologic plausibility ranges. The MR60BHA2 emits real but uninformative
// numbers (1-5 BPM) while it locks onto a target — those should NOT promote
// to the live or held-good slots, otherwise the iOS app's own plausibility
// gate will keep masking the radar entirely. Filtering here means the held
// value stays the last RELIABLE reading instead of "the most recent number
// the radar happened to print."
const HR_PLAUSIBLE_MIN_BPM: f64 = 40.0;
const HR_PLAUSIBLE_MAX_BPM: f64 = 200.0;
const BR_PLAUSIBLE_MIN_BPM: f64 = 8.0;
const BR_PLAUSIBLE_MAX_BPM: f64 = 35.0;

// How long to keep reporting `person_present: true` after the radar's last
// confirmed positive reading. 2s comfortably outlasts the radar's typical
// frame-to-frame lock churn (~0.5-2 s) and keeps walk-out latency tight
// for the demo. If the iOS view starts flapping during a sit-still test,
// bump back to 4s. iOS adds its own 3s sticky on top of this.
const PRESENCE_STICKY_WINDOW: Duration = Duration::from_secs(2);

// MR60BHA2 fallback: if `has_target` hasn't locked but the radar's
// `target_distance` value is updating, treat that as evidence of someone
// transiently in the cone (walking through). This window controls how
// long the inferred presence persists after the last distance change.
const DISTANCE_MOTION_WINDOW: Duration = Duration::from_secs(3);

impl RadarState {
    fn note_hr(&mut self, v: f64) {
        if (HR_PLAUSIBLE_MIN_BPM..=HR_PLAUSIBLE_MAX_BPM).contains(&v) {
            self.heart_rate_bpm = Some(v);
            self.held_hr = Some(v);
            self.held_at = Some(Instant::now());
        }
        // Implausible: do not touch state. snapshot() will fall back to
        // held_hr (within hold_max_age), then to None — preferable to
        // surfacing 1-BPM noise while the radar is still settling.
    }
    fn note_br(&mut self, v: f64) {
        if (BR_PLAUSIBLE_MIN_BPM..=BR_PLAUSIBLE_MAX_BPM).contains(&v) {
            self.breath_rate_bpm = Some(v);
            self.held_br = Some(v);
            self.held_at = Some(Instant::now());
        }
    }
    fn note_dist(&mut self, cm: u16) {
        // Record a "distance changed" event whenever the value materially
        // moves AND is non-zero. Used by snapshot() to infer transient
        // motion when MR60BHA2's strict has_target lock hasn't fired yet.
        if cm > 0 {
            let changed = match self.last_distance_value {
                Some(prev) => prev.abs_diff(cm) >= 5,  // >= 5 cm jump
                None => true,
            };
            if changed {
                self.last_distance_change_at = Some(Instant::now());
            }
            self.last_distance_value = Some(cm);
        }
        self.target_distance_cm = Some(cm);
    }
    fn note_rssi(&mut self, dbm: i8) {
        self.wifi_rssi_dbm = Some(dbm);
    }
    fn note_present(&mut self, p: bool) {
        if p {
            self.person_present = true;
            self.last_presence_true_at = Some(Instant::now());
        } else {
            // Sticky-OFF: only clear if it's been more than PRESENCE_STICKY_WINDOW
            // since we last saw a confirmed positive. This rides out the radar's
            // momentary lock-drop between frames without making "person left the
            // room" detection sluggish (the window is short).
            let still_held = self
                .last_presence_true_at
                .map(|t| Instant::now().duration_since(t) < PRESENCE_STICKY_WINDOW)
                .unwrap_or(false);
            if !still_held {
                self.person_present = false;
                self.heart_rate_bpm = None;
                self.breath_rate_bpm = None;
                self.target_distance_cm = None;
            }
            // Otherwise: keep person_present=true and keep the live HR/BR/dist
            // values so vitals don't drop to zero through micro-flickers.
        }
    }

    /// Distance-change inference: if the MR60BHA2's `has_target` hasn't
    /// locked (so person_present is false), but `target_distance` changed in
    /// the last DISTANCE_MOTION_WINDOW, treat that as evidence of someone
    /// walking through the cone. Used by snapshot().
    fn distance_indicates_motion(&self) -> bool {
        self.last_distance_change_at
            .map(|t| Instant::now().duration_since(t) <= DISTANCE_MOTION_WINDOW)
            .unwrap_or(false)
    }

    /// Resolve a current packet snapshot, applying held-value fallback within
    /// `hold_max_age` so brief radar drop-outs don't zero the output.
    fn snapshot(&mut self, hold_max_age: Duration) -> RadarSnapshot {
        let held_recent = self
            .held_at
            .map(|t| Instant::now().duration_since(t) <= hold_max_age)
            .unwrap_or(false);

        let hr_out = self
            .heart_rate_bpm
            .or(if held_recent { self.held_hr } else { None })
            .unwrap_or(0.0);
        let br_out = self
            .breath_rate_bpm
            .or(if held_recent { self.held_br } else { None })
            .unwrap_or(0.0);

        // Approximate motion_energy via HR/BR drift between ticks, smoothed.
        let raw_motion = if self.person_present {
            let dhr = self.last_hr_seen.map(|p| (hr_out - p).abs()).unwrap_or(0.0);
            let dbr = self.last_br_seen.map(|p| (br_out - p).abs()).unwrap_or(0.0);
            (0.5 * dhr + dbr).clamp(0.0, 50.0) as f32
        } else {
            0.0
        };
        self.motion_energy_ema = 0.3 * raw_motion + 0.7 * self.motion_energy_ema;
        if hr_out > 0.0 {
            self.last_hr_seen = Some(hr_out);
        }
        if br_out > 0.0 {
            self.last_br_seen = Some(br_out);
        }

        // Distance-motion fallback: when has_target hasn't locked but the
        // radar IS updating distance, surface presence + motion so the iOS
        // app shows "someone is walking through" instead of a flat zero.
        let distance_motion = !self.person_present && self.distance_indicates_motion();

        // Vital-signs fallback (2026-06-17): the MR60BHA2 has two parallel
        // detection paths. With a near-field clutter target (e.g. the bench
        // 23 cm in front of the antenna), `person_present` stays OFF even
        // when the radar's heart-rate/breath-rate channels are actively
        // measuring a real human. Treat HR as presence evidence — but ONLY
        // HR, not BR. BR alone gets faked by static reflectors (the radar
        // measures BR off any oscillating reflection); HR requires actual
        // pulse-rate signal processing that doesn't lock onto furniture.
        let vitals_evidence = !self.person_present && !distance_motion
            && hr_out > 0.0;

        let effective_present = self.person_present || distance_motion || vitals_evidence;
        RadarSnapshot {
            present: effective_present,
            motion: self.motion_energy_ema > 0.5 || distance_motion,
            heart_rate_bpm: hr_out,
            breath_rate_bpm: br_out,
            target_distance_cm: self.target_distance_cm.unwrap_or(0),
            rssi_dbm: self.wifi_rssi_dbm.unwrap_or(0),
            motion_energy: self.motion_energy_ema,
            // Confidence ladder by detection path:
            //   person_present  → 0.85  (radar's full target lock)
            //   vitals only     → 0.70  (HR/BR detected, no target lock)
            //   distance motion → 0.55  (walking through, no HR yet)
            //   nothing         → 0.05
            presence_score: if self.person_present {
                0.85
            } else if vitals_evidence {
                0.70
            } else if distance_motion {
                0.55
            } else {
                0.05
            },
            n_persons: if effective_present { 1 } else { 0 },
        }
    }
}

#[derive(Debug, Clone)]
struct RadarSnapshot {
    present: bool,
    motion: bool,
    heart_rate_bpm: f64,
    breath_rate_bpm: f64,
    target_distance_cm: u16,
    rssi_dbm: i8,
    motion_energy: f32,
    presence_score: f32,
    n_persons: u8,
}

// ─── HTTP fallback types ────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct EspNumericSensor {
    value: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct EspBinarySensor {
    value: Option<bool>,
}

fn http_get_numeric(agent: &ureq::Agent, base: &str, path: &str) -> Result<Option<f64>, String> {
    let url = format!("{base}{path}");
    let resp = agent
        .get(&url)
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    let body: EspNumericSensor = resp
        .into_json()
        .map_err(|e| format!("parse {url}: {e}"))?;
    Ok(body.value)
}

fn http_get_bool(agent: &ureq::Agent, base: &str, path: &str) -> Result<Option<bool>, String> {
    let url = format!("{base}{path}");
    let resp = agent
        .get(&url)
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    let body: EspBinarySensor = resp
        .into_json()
        .map_err(|e| format!("parse {url}: {e}"))?;
    Ok(body.value)
}

// ─── Packet encoding ────────────────────────────────────────────────────────

/// Build a 32-byte ADR-039 edge-vitals packet from a radar snapshot.
/// Layout mirrors `parse_esp32_vitals` in `main.rs`. `radar_type` is
/// parameterised so the same bridge can carry MR60BHA2 (vitals) or LD2410
/// (presence + range only) data — only byte 14 changes.
fn encode_vitals_packet(
    node_id: u8,
    radar_type: u8,
    s: &RadarSnapshot,
    timestamp_ms: u32,
) -> [u8; 32] {
    let mut buf = [0u8; 32];
    buf[0..4].copy_from_slice(&VITALS_MAGIC.to_le_bytes());
    buf[4] = node_id;

    // bit0=presence, bit1=fall, bit2=motion, bit3=radar_present
    let mut flags: u8 = 0;
    if s.present {
        flags |= 0x01;
        flags |= 0x08;
    }
    if s.motion {
        flags |= 0x04;
    }
    buf[5] = flags;

    let br_raw = (s.breath_rate_bpm.clamp(0.0, 65535.0 / 100.0) * 100.0).round() as u16;
    buf[6..8].copy_from_slice(&br_raw.to_le_bytes());

    let hr_raw =
        (s.heart_rate_bpm.clamp(0.0, u32::MAX as f64 / 10000.0) * 10_000.0).round() as u32;
    buf[8..12].copy_from_slice(&hr_raw.to_le_bytes());

    buf[12] = s.rssi_dbm as u8;
    buf[13] = s.n_persons;
    buf[14] = radar_type;
    buf[15] = if s.present { 1 } else { 0 };

    buf[16..20].copy_from_slice(&s.motion_energy.to_le_bytes());
    buf[20..24].copy_from_slice(&s.presence_score.to_le_bytes());
    buf[24..28].copy_from_slice(&timestamp_ms.to_le_bytes());
    buf[28..30].copy_from_slice(&s.target_distance_cm.to_le_bytes());
    buf
}

fn emit(
    socket: &UdpSocket,
    dest: &str,
    node_id: u8,
    radar_type: u8,
    snap: &RadarSnapshot,
    start: Instant,
) {
    let ts = (Instant::now().duration_since(start).as_millis() as u32).max(1);
    let pkt = encode_vitals_packet(node_id, radar_type, snap, ts);
    match socket.send_to(&pkt, dest) {
        Ok(_) => debug!(
            "radar → UDP: node={} type={} present={} hr={:.1} br={:.1} dist={}cm rssi={}",
            node_id,
            radar_type,
            snap.present,
            snap.heart_rate_bpm,
            snap.breath_rate_bpm,
            snap.target_distance_cm,
            snap.rssi_dbm
        ),
        Err(e) => warn!("radar bridge (node={node_id}): UDP send to {dest} failed: {e}"),
    }
}

// ─── Public entry points ───────────────────────────────────────────────────

/// Spawn the bridge on dedicated OS threads.
pub fn spawn(config: C6RadarConfig) {
    let state = Arc::new(Mutex::new(RadarState::default()));
    let start = Instant::now();

    // MQTT subscriber thread — push-driven; emits on each state change.
    if config.mqtt_host.is_some() {
        let state = state.clone();
        let cfg = config.clone();
        std::thread::Builder::new()
            .name("c6-mqtt".into())
            .spawn(move || mqtt_loop(cfg, state, start))
            .expect("c6-mqtt thread spawn failed");
    }

    // HTTP fallback thread — polls every poll_interval; emits only when MQTT
    // has been quiet for `mqtt_quiet_timeout` (or when MQTT is disabled).
    let mqtt_disabled = config.mqtt_host.is_none();
    std::thread::Builder::new()
        .name("c6-http".into())
        .spawn(move || http_loop(config, state, start, mqtt_disabled))
        .expect("c6-http thread spawn failed");
}

// ─── MQTT thread ────────────────────────────────────────────────────────────

fn mqtt_loop(cfg: C6RadarConfig, state: Arc<Mutex<RadarState>>, start: Instant) {
    use rumqttc::{Client, Event, MqttOptions, Packet, QoS};

    let host = match &cfg.mqtt_host {
        Some(h) => h.clone(),
        None => return,
    };
    let prefix = cfg.mqtt_topic_prefix.trim_end_matches('/').to_string();
    let client_id = format!("ruview-c6-bridge-{}", std::process::id());
    info!(
        "C6 MQTT: connecting to {host}:{} client={} prefix={}",
        cfg.mqtt_port, client_id, prefix
    );

    let mut opts = MqttOptions::new(client_id, host, cfg.mqtt_port);
    opts.set_keep_alive(Duration::from_secs(30));
    opts.set_clean_session(true);

    let dest = format!("127.0.0.1:{}", cfg.udp_port);
    let socket = match UdpSocket::bind("127.0.0.1:0") {
        Ok(s) => s,
        Err(e) => {
            warn!("C6 MQTT: cannot bind local UDP socket: {e}");
            return;
        }
    };

    // Outer reconnect loop. rumqttc's blocking Client reconnects internally
    // via the event-loop iterator, but if `iter().next()` returns Err in a
    // way that breaks the loop, we rebuild from scratch with backoff.
    loop {
        let (client, mut connection) = Client::new(opts.clone(), 16);
        let topics = [
            format!("{prefix}/sensor/heart_rate/state"),
            format!("{prefix}/sensor/breath_rate/state"),
            format!("{prefix}/sensor/target_distance/state"),
            format!("{prefix}/sensor/wifi_rssi/state"),
            format!("{prefix}/binary_sensor/person_present/state"),
        ];
        for t in &topics {
            if let Err(e) = client.subscribe(t, QoS::AtLeastOnce) {
                warn!("C6 MQTT: subscribe {t} failed: {e}");
            } else {
                debug!("C6 MQTT: subscribed {t}");
            }
        }

        let mut connect_logged = false;
        for notification in connection.iter() {
            match notification {
                Ok(Event::Incoming(Packet::ConnAck(_))) => {
                    if !connect_logged {
                        info!("C6 MQTT: connected, subscriptions live");
                        connect_logged = true;
                    }
                }
                Ok(Event::Incoming(Packet::Publish(p))) => {
                    let topic = p.topic.clone();
                    let payload = String::from_utf8_lossy(&p.payload).to_string();
                    let snap_for_emit = {
                        let mut st = state.lock().unwrap();
                        st.last_mqtt_seen = Some(Instant::now());
                        apply_mqtt_message(&prefix, &topic, &payload, &mut st);
                        Some(st.snapshot(Duration::from_secs(20)))
                    };
                    if let Some(snap) = snap_for_emit {
                        emit(&socket, &dest, cfg.node_id, cfg.radar_type, &snap, start);
                    }
                }
                Ok(_) => { /* ping, suback, etc. — ignore */ }
                Err(e) => {
                    warn!("C6 MQTT: event-loop error: {e}; will reconnect");
                    break;
                }
            }
        }

        std::thread::sleep(Duration::from_secs(2));
    }
}

/// Update `state` from one ESPHome MQTT message. ESPHome publishes plain
/// strings, not JSON, on `<prefix>/<domain>/<sensor_name>/state` topics.
fn apply_mqtt_message(prefix: &str, topic: &str, payload: &str, st: &mut RadarState) {
    let trimmed_topic = topic.trim_start_matches('/');
    let trimmed_prefix = prefix.trim_start_matches('/');
    let suffix = match trimmed_topic.strip_prefix(trimmed_prefix) {
        Some(s) => s.trim_start_matches('/'),
        None => return,
    };
    let payload_trim = payload.trim();
    match suffix {
        "sensor/heart_rate/state" => {
            if let Ok(v) = payload_trim.parse::<f64>() {
                st.note_hr(v);
            }
        }
        "sensor/breath_rate/state" => {
            if let Ok(v) = payload_trim.parse::<f64>() {
                st.note_br(v);
            }
        }
        "sensor/target_distance/state" => {
            if let Ok(v) = payload_trim.parse::<f64>() {
                st.note_dist(v.clamp(0.0, 65535.0) as u16);
            }
        }
        "sensor/wifi_rssi/state" => {
            if let Ok(v) = payload_trim.parse::<f64>() {
                st.note_rssi(v.clamp(-128.0, 127.0) as i8);
            }
        }
        "binary_sensor/person_present/state" => {
            let present = matches!(payload_trim.to_ascii_uppercase().as_str(), "ON" | "TRUE" | "1");
            st.note_present(present);
        }

        // ─── LD2410-specific topics (no HR/BR; range comes from multiple
        // fields, and presence has a more granular moving/still split). ──
        "sensor/moving_distance/state"
        | "sensor/still_distance/state"
        | "sensor/detection_distance/state" => {
            if let Ok(v) = payload_trim.parse::<f64>() {
                // Any distance reading is usable; prefer the most recent one.
                st.note_dist(v.clamp(0.0, 65535.0) as u16);
            }
        }
        "binary_sensor/moving_target_present/state"
        | "binary_sensor/still_target_present/state" => {
            // Either moving or still target counts as "presence". The
            // `person_present` binary sensor in the YAML already OR's these
            // and applies delayed_off, so this is a belt-and-suspenders path.
            let present = matches!(payload_trim.to_ascii_uppercase().as_str(), "ON" | "TRUE" | "1");
            if present {
                st.note_present(true);
            }
        }
        _ => {} // ignore other topics (e.g. uptime, ip_address)
    }
}

// ─── HTTP fallback thread ───────────────────────────────────────────────────

fn http_loop(
    cfg: C6RadarConfig,
    state: Arc<Mutex<RadarState>>,
    start: Instant,
    mqtt_disabled: bool,
) {
    let label = if mqtt_disabled { "HTTP-only" } else { "HTTP heartbeat" };
    info!(
        "C6 {label}: polling http://{} every {}ms → UDP 127.0.0.1:{} node={}",
        cfg.http_host,
        cfg.http_poll_interval.as_millis(),
        cfg.udp_port,
        cfg.node_id
    );

    let base = format!("http://{}", cfg.http_host);
    let agent: ureq::Agent = ureq::AgentBuilder::new()
        .timeout(cfg.http_timeout)
        .build();
    let dest = format!("127.0.0.1:{}", cfg.udp_port);
    let socket = match UdpSocket::bind("127.0.0.1:0") {
        Ok(s) => s,
        Err(e) => {
            warn!("C6 {label}: cannot bind UDP: {e}");
            return;
        }
    };

    // For HTTP-only mode, poll every poll_interval. For fallback mode, poll
    // every poll_interval and only emit when MQTT has been quiet — we still
    // refresh the cached values regularly so a fallback emission has fresh data.
    let mut consecutive_failures: u32 = 0;
    loop {
        let hr_r = http_get_numeric(&agent, &base, "/sensor/heart_rate");
        let br_r = http_get_numeric(&agent, &base, "/sensor/breath_rate");
        let dist_r = http_get_numeric(&agent, &base, "/sensor/target_distance");
        let rssi_r = http_get_numeric(&agent, &base, "/sensor/wifi_rssi");
        let pres_r = http_get_bool(&agent, &base, "/binary_sensor/person_present");

        let all_failed = hr_r.is_err()
            && br_r.is_err()
            && dist_r.is_err()
            && rssi_r.is_err()
            && pres_r.is_err();
        if all_failed {
            consecutive_failures += 1;
            if consecutive_failures == 1 || consecutive_failures % 20 == 0 {
                warn!(
                    "C6 {label}: all endpoints unreachable (failure #{}). Will keep retrying.",
                    consecutive_failures
                );
            }
            std::thread::sleep(cfg.http_poll_interval);
            continue;
        }
        consecutive_failures = 0;

        // Update shared state from whatever succeeded.
        {
            let mut st = state.lock().unwrap();
            if let Ok(Some(v)) = pres_r {
                st.note_present(v);
            }
            if let Ok(Some(v)) = hr_r {
                st.note_hr(v);
            }
            if let Ok(Some(v)) = br_r {
                st.note_br(v);
            }
            if let Ok(Some(v)) = dist_r {
                st.note_dist(v.clamp(0.0, 65535.0) as u16);
            }
            if let Ok(Some(v)) = rssi_r {
                st.note_rssi(v.clamp(-128.0, 127.0) as i8);
            }
        }

        // Always emit a heartbeat on every poll, regardless of MQTT activity
        // (2026-06-12 fix). ESPHome dedupes consecutive identical values, so
        // when the radar's readings are stable there can be multi-second gaps
        // between MQTT publishes. Without an independent heartbeat the
        // server's per-node `last_frame_time` grows and the iOS app shows
        // Node 4 going offline even though everything is healthy. The
        // duplicate-on-MQTT case is harmless: the UDP receiver just stamps
        // `last_frame_time` again with the same vitals.
        let should_emit = true;

        if should_emit {
            let snap = state.lock().unwrap().snapshot(Duration::from_secs(20));
            emit(&socket, &dest, cfg.node_id, cfg.radar_type, &snap, start);
        }

        std::thread::sleep(cfg.http_poll_interval);
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(present: bool, hr: f64, br: f64, dist: u16) -> RadarSnapshot {
        RadarSnapshot {
            present,
            motion: false,
            heart_rate_bpm: hr,
            breath_rate_bpm: br,
            target_distance_cm: dist,
            rssi_dbm: -58,
            motion_energy: 0.0,
            presence_score: if present { 0.85 } else { 0.05 },
            n_persons: if present { 1 } else { 0 },
        }
    }

    #[test]
    fn packet_has_correct_magic_and_node_id() {
        let pkt = encode_vitals_packet(1, RADAR_TYPE_MR60BHA2, &snap(true, 72.0, 18.0, 145), 1234);
        let magic = u32::from_le_bytes([pkt[0], pkt[1], pkt[2], pkt[3]]);
        assert_eq!(magic, VITALS_MAGIC);
        assert_eq!(pkt[4], 1);
    }

    #[test]
    fn presence_flags() {
        // present=true ⇒ bit0 + bit3
        let pkt = encode_vitals_packet(1, RADAR_TYPE_MR60BHA2, &snap(true, 72.0, 18.0, 145), 1);
        assert_eq!(pkt[5] & 0x01, 0x01);
        assert_eq!(pkt[5] & 0x08, 0x08);
        // absent
        let pkt = encode_vitals_packet(1, RADAR_TYPE_MR60BHA2, &snap(false, 0.0, 0.0, 0), 1);
        assert_eq!(pkt[5], 0x00);
    }

    #[test]
    fn radar_type_byte_reflects_argument() {
        let pkt = encode_vitals_packet(1, RADAR_TYPE_MR60BHA2, &snap(true, 72.0, 18.0, 145), 1);
        assert_eq!(pkt[14], 1);
        let pkt = encode_vitals_packet(2, RADAR_TYPE_LD2410, &snap(true, 0.0, 0.0, 250), 1);
        assert_eq!(pkt[14], 2);
        assert_eq!(pkt[4], 2);
    }

    #[test]
    fn breath_and_heart_rates_pack_correctly() {
        let pkt = encode_vitals_packet(1, RADAR_TYPE_MR60BHA2, &snap(true, 72.25, 18.5, 0), 1);
        let br_raw = u16::from_le_bytes([pkt[6], pkt[7]]);
        let hr_raw = u32::from_le_bytes([pkt[8], pkt[9], pkt[10], pkt[11]]);
        assert_eq!(br_raw, 1850);
        assert_eq!(hr_raw, 722_500);
    }

    #[test]
    fn distance_in_bytes_28_29() {
        let pkt = encode_vitals_packet(1, RADAR_TYPE_MR60BHA2, &snap(true, 0.0, 0.0, 145), 1);
        assert_eq!(u16::from_le_bytes([pkt[28], pkt[29]]), 145);
    }

    #[test]
    fn ld2410_topics_parse() {
        let mut st = RadarState::default();
        apply_mqtt_message(
            "ruview-s3-ld2410-n2",
            "ruview-s3-ld2410-n2/sensor/moving_distance/state",
            "250",
            &mut st,
        );
        assert_eq!(st.target_distance_cm, Some(250));
        apply_mqtt_message(
            "ruview-s3-ld2410-n2",
            "ruview-s3-ld2410-n2/binary_sensor/moving_target_present/state",
            "ON",
            &mut st,
        );
        assert!(st.person_present);
        apply_mqtt_message(
            "ruview-s3-ld2410-n2",
            "ruview-s3-ld2410-n2/sensor/still_distance/state",
            "180",
            &mut st,
        );
        assert_eq!(st.target_distance_cm, Some(180));
    }

    #[test]
    fn apply_mqtt_message_parses_state_topics() {
        let mut st = RadarState::default();
        apply_mqtt_message("ruview-c6-radar", "ruview-c6-radar/sensor/heart_rate/state", "72.0", &mut st);
        assert_eq!(st.heart_rate_bpm, Some(72.0));
        apply_mqtt_message("ruview-c6-radar", "ruview-c6-radar/sensor/breath_rate/state", "18.0", &mut st);
        assert_eq!(st.breath_rate_bpm, Some(18.0));
        apply_mqtt_message("ruview-c6-radar", "ruview-c6-radar/sensor/target_distance/state", "145", &mut st);
        assert_eq!(st.target_distance_cm, Some(145));
        apply_mqtt_message("ruview-c6-radar", "ruview-c6-radar/sensor/wifi_rssi/state", "-58", &mut st);
        assert_eq!(st.wifi_rssi_dbm, Some(-58));
        apply_mqtt_message("ruview-c6-radar", "ruview-c6-radar/binary_sensor/person_present/state", "ON", &mut st);
        assert!(st.person_present);
        // Sticky-OFF: a transient OFF right after an ON does NOT immediately
        // clear presence (PRESENCE_STICKY_WINDOW masks single-frame drops).
        apply_mqtt_message("ruview-c6-radar", "ruview-c6-radar/binary_sensor/person_present/state", "OFF", &mut st);
        assert!(st.person_present, "sticky window keeps presence=true through brief OFF");
    }

    #[test]
    fn apply_mqtt_message_ignores_unrelated_topics() {
        let mut st = RadarState::default();
        apply_mqtt_message("ruview-c6-radar", "other/topic/state", "42", &mut st);
        assert!(st.heart_rate_bpm.is_none());
    }

    #[test]
    fn snapshot_holds_last_good_within_window() {
        let mut st = RadarState::default();
        st.note_hr(72.0);
        st.note_present(false); // simulates "no target" — clears live HR
        let snap = st.snapshot(Duration::from_secs(20));
        assert_eq!(snap.heart_rate_bpm, 72.0); // held value still surfaces
    }

    #[test]
    fn implausible_vitals_are_filtered_at_the_bridge() {
        let mut st = RadarState::default();
        // Seed a known-good value first.
        st.note_br(15.0);
        // Radar then emits a "settling" 4 BPM — must NOT replace the good one.
        st.note_br(4.0);
        let snap = st.snapshot(Duration::from_secs(20));
        assert_eq!(snap.breath_rate_bpm, 15.0);

        // Same for HR — bogus 28 BPM (well below resting floor) is ignored.
        st.note_hr(72.0);
        st.note_hr(28.0);
        let snap = st.snapshot(Duration::from_secs(20));
        assert_eq!(snap.heart_rate_bpm, 72.0);
    }
}
