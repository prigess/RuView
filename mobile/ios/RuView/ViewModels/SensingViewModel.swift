import SwiftUI
import Combine
import UIKit

// MARK: - SensingViewModel

@MainActor
final class SensingViewModel: ObservableObject {

    // MARK: - The underlying client (exposed for direct use in wizard)
    let client: RuViewClient

    // MARK: - C6 60GHz radar (direct ESPHome poller)
    let radarClient: C6RadarClient
    @Published var radarReading: C6RadarReading?
    @Published var radarReachable: Bool = false

    /// IP address of the ESP32-C6 ESPHome node. Defaults to the current
    /// NorimNetwork DHCP lease; flip to the static reservation once it's
    /// pinned in the router. Stored in UserDefaults under "c6RadarHost"
    /// so a future settings screen can edit it without changing this class.
    private var c6RadarHost: String {
        UserDefaults.standard.string(forKey: "c6RadarHost") ?? "192.168.8.228"
    }

    // MARK: - LD2450 24GHz tracking radar (direct ESPHome poller)
    let ld2450Client: LD2450Client
    @Published var ld2450Reading: LD2450Reading?
    @Published var ld2450Reachable: Bool = false

    /// IP of the LD2450 ESPHome node. Stored in UserDefaults ("ld2450Host")
    /// so a settings screen can edit it without touching this class.
    private var ld2450Host: String {
        UserDefaults.standard.string(forKey: "ld2450Host") ?? "192.168.8.184"
    }

    // MARK: - LD2410C 24GHz presence radar (direct ESPHome poller)
    let ld2410Client: LD2410Client
    @Published var ld2410Reading: LD2410Reading?
    @Published var ld2410Reachable: Bool = false

    private var ld2410Host: String {
        UserDefaults.standard.string(forKey: "ld2410Host") ?? "192.168.8.132"
    }

    // MARK: - INMP441 audio node (direct ESPHome poller)
    let micClient: MicClient
    @Published var micReading: MicReading?
    @Published var micReachable: Bool = false

    // ── Voice intelligence (Orange Pi ruview-audiod, :3025) ──────────────────
    // The Pi does all the audio work (ESP32 mic → YAMNet → radar fusion); the
    // app just renders the fused result. This is the live sound source now.
    let audioClient: AudioClient
    @Published var audioReading: AudioReading?
    @Published var audioReachable: Bool = false

    // ── BLE heart rate (Orange Pi ruview-hrd bridge, :3027) ──────────────────
    // A BLE HR strap/ring (0x180D) → ruview-ble-hr-decoder → MQTT → ruview-hrd.
    // The cheap, trustworthy, contact-based vitals source (HR + HRV) — accurate
    // where the C6 radar was flaky. The Pi owns BLE + decode; app renders.
    let hrClient: BLEHeartClient
    @Published var bleHeartReading: BLEHeartReading?
    @Published var bleHrReachable: Bool = false

    // ── CSI person-count CNN (Orange Pi ruview-countd, :3028) ────────────────
    // ruview-countd supervises the cog-person-count Candle model; this surfaces
    // its count. Idle until CSI is flowing. Distinct from the LD2450 radar count
    // — a model-driven second opinion, not (yet) the authoritative hero count.
    let countClient: CountClient
    @Published var modelCountReading: ModelCountReading?
    @Published var modelCountReachable: Bool = false

    // ── Mic-derived signals (loudness only, until the voice-streaming upgrade) ──
    /// Current A-weighted sound level (Leq, dBFS — negative).
    @Published var soundLevelDb: Double?
    /// True when the room is meaningfully louder than its ambient floor —
    /// someone talking / moving / active.
    @Published var soundActive: Bool = false
    /// Latched for a few seconds after a sharp loud peak (clap, shout, thud) —
    /// a possible impact / call-for-help. The elder-care "loud event" trigger.
    @Published var impactDetected: Bool = false
    /// Adaptive ambient noise floor (EMA of quiet samples), for the above.
    private var soundBaselineDb: Double = -45
    private var soundBaselineSeeded: Bool = false
    private var lastImpactAt: Date?

    /// Update the mic-derived signals from one reading. Seeds an ambient floor,
    /// then flags "active" when Leq rises above it and "impact" on a peak spike.
    private func ingestMic(_ reading: MicReading?) {
        guard let leq = reading?.leqDb, leq.isFinite else { return }
        soundLevelDb = leq
        if !soundBaselineSeeded {
            soundBaselineDb = leq
            soundBaselineSeeded = true
        } else if leq < soundBaselineDb + 10 {
            // Only quiet-ish samples pull the floor; loud spikes don't raise it.
            soundBaselineDb = 0.05 * leq + 0.95 * soundBaselineDb
        }
        soundActive = leq > soundBaselineDb + 8
        let peak = reading?.peakDb ?? leq
        if peak > soundBaselineDb + 20 || peak > -12 {
            lastImpactAt = Date()
        }
        impactDetected = lastImpactAt.map { Date().timeIntervalSince($0) < 4 } ?? false
    }

    /// Whether the LD2450's antenna is attached. With the antenna on (the
    /// normal state) the radar gives a trustworthy multi-target count, so this
    /// defaults to TRUE. Antenna-less, the LD2450 emits stable ghost targets at
    /// arbitrary in-range positions (observed at 2–7 m) that no spatial filter
    /// can separate from a real person; set this flag to false ("safe mode") to
    /// fall back to counting from the presence sensors (LD2410C + C6) only.
    var ld2450AntennaConnected: Bool {
        UserDefaults.standard.object(forKey: "ld2450AntennaConnected") as? Bool ?? true
    }

    // MARK: - Published state mirrored from client
    @Published var snapshot: SensingSnapshot?
    @Published var isConnected: Bool = false
    @Published var connectionError: String?
    @Published var isSignalLost: Bool = false

    /// Debounced "show the disconnected banner" — true only after the connection has
    /// been down for at least `disconnectGracePeriod` seconds. Brief reconnects don't
    /// flash the banner.
    @Published var showDisconnectedBanner: Bool = false
    private let disconnectGracePeriod: TimeInterval = 3.5
    private var disconnectGraceTask: Task<Void, Never>?

    // MARK: - REST-fetched state
    @Published var nodes: [NodeStatus] = []
    @Published var zones: [ZoneInfo] = []
    @Published var adaptiveStatus: AdaptiveStatus?
    @Published var calibrationStatus: CalibrationStatus?

    @Published var nodesLoading: Bool = false
    @Published var zonesLoading: Bool = false
    @Published var nodesError: String?
    @Published var zonesError: String?

    // MARK: - First connect timestamp for "Measuring..." state
    private var connectedAt: Date?

    // MARK: - Live data history for sparklines (sampled at ~1 Hz)
    @Published var heartRateHistory: [Double] = []
    @Published var breathingHistory: [Double] = []
    @Published var personCountHistory: [Double] = []
    @Published var nodeRssiHistory: [Int: [Double]] = [:]

    /// `true` when ticks have advanced within the last 1.5s — used for the "Live" pulse indicator.
    @Published var isLiveDataFlowing: Bool = false
    private var lastTickValue: Int = 0
    private var lastTickChangeAt: Date = .distantPast

    // EMA smoothing state — heavy smoothing so numbers don't flicker
    private var emaHeartRate: Double?
    private var emaBreathing: Double?
    private let emaAlpha: Double = 0.08
    private var lastHistorySample = Date.distantPast
    private let historyLength: Int = 60

    // Display-value hysteresis — only commit a rounded change when the EMA has
    // moved past the integer boundary by `hysteresisMargin` units. Prevents the
    // typical 56↔57↔56 flicker when the true value sits near a boundary.
    @Published var displayHeartRate: Int?
    @Published var displayBreathingRate: Int?
    @Published var displayPersonCount: Int = 0
    private let hysteresisMargin: Double = 0.6

    // Person count needs N consecutive identical readings before changing,
    // so transient mis-detections don't flip the displayed number.
    private var pendingPersonCount: Int = -1
    private var pendingPersonCountStreak: Int = 0
    private let personCountStabilityFrames: Int = 4

    // Sticky binary presence — the raw classification.presence flag flaps at
    // up to 10 Hz near the classifier's confidence threshold, and a person
    // sitting still or briefly outside one node's FoV can produce 1-2s of
    // false-absent. For the Occupancy hero, we use two rules:
    //
    //   1. Empty → Present is immediate (a positive detection is never hidden).
    //   2. Present → Empty requires `presenceStickyDuration` seconds of
    //      *continuous* absent classification AND motion_level == "absent".
    //      Any movement keeps the room "Present" regardless of presence flag.
    //
    // 1s sticky after no evidence (was 2s, was 3s, was 10s). Combined
    // with the bridge's 1s PRESENCE_STICKY_WINDOW gives a ~2s walk-out
    // worst-case. The bridge already absorbs the radar's frame-to-frame
    // lock churn (~1.3s avg, 1.9s p100 in bench data), so this view-layer
    // sticky now just smooths over single-tick gaps.
    @Published var displayPresence: Bool = false
    private var lastEvidenceOfPresenceAt: Date?
    private let presenceStickyDuration: TimeInterval = 1.0

    // MARK: - Presence timeline + time-in-state
    //
    // For the caregiver UX the question is never "is the radar working?"
    // it's "is mom in the room *now* and how long has she been there/gone?"
    // Track the moment displayPresence last flipped + keep a 24 h rolling
    // log of (timestamp, present) for the timeline strip.
    @Published var presenceChangedAt: Date = Date()
    @Published var lastTimePresent: Date? = nil
    struct PresenceSample: Identifiable {
        let id = UUID()
        let at: Date
        let present: Bool
    }
    @Published var presenceHistory: [PresenceSample] = []
    private let presenceHistoryRetention: TimeInterval = 24 * 3600

    // MARK: - Known-good value fallback
    //
    // When the live reading is unreliable (low confidence or out of physiologic
    // range), we hold the last "good" value instead of showing "–" or noise.
    @Published var lastGoodHeartRate: Int?
    @Published var lastGoodBreathingRate: Int?
    private var lastGoodHeartRateAt: Date?
    private var lastGoodBreathingRateAt: Date?

    /// Resting-adult physiologic plausibility ranges. Anything outside is
    /// treated as a sensor failure even if the model reports it confidently.
    private let heartRatePlausibleRange: ClosedRange<Int> = 40...180
    private let breathingRatePlausibleRange: ClosedRange<Int> = 6...35
    private let goodSampleConfidence: Double = 0.55
    private let heldValueMaxAge: TimeInterval = 300   // 5 minutes

    // MARK: - Polling tasks
    // Single source of truth for REST poll cadence. NodeHealthView reads
    // these to render its "Refreshes every Ns" footer so the label can't
    // drift from the actual interval.
    let nodesPollIntervalSeconds: TimeInterval = 1.0
    let zonesPollIntervalSeconds: TimeInterval = 2.0
    private var nodesPollTask: Task<Void, Never>?
    private var zonesPollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        self.client = RuViewClient()
        self.radarClient = C6RadarClient()
        self.ld2450Client = LD2450Client()
        self.ld2410Client = LD2410Client()
        self.micClient = MicClient()
        self.audioClient = AudioClient()
        self.hrClient = BLEHeartClient()
        self.countClient = CountClient()
        bindClientPublishers()
        bindRadarPublishers()
        bindLD2450Publishers()
        bindLD2410Publishers()
        bindMicPublishers()
        bindAudioPublishers()
        bindHRPublishers()
        bindCountPublishers()
    }

    private func bindHRPublishers() {
        hrClient.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$bleHeartReading)
        hrClient.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$bleHrReachable)
    }

    private func bindCountPublishers() {
        countClient.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$modelCountReading)
        countClient.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$modelCountReachable)
    }

    private func bindAudioPublishers() {
        audioClient.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$audioReading)
        audioClient.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$audioReachable)
        // Feed the presence state-machine from the DIRECT radars — the server
        // snapshot is starved (tick 0), so displayPresence/time-in-state/timeline
        // must be driven by the LD2410C/LD2450 directly, same as the count hero.
        Publishers.Merge(
            ld2410Client.$reading.map { _ in () },
            ld2450Client.$reading.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self else { return }
            let ml = self.fusedMotionState == "moving" ? "present_moving"
                   : self.fusedMotionState == "still" ? "present_still" : "absent"
            self.updateStablePresence(presence: self.anyPresenceEvidence, motionLevel: ml)
        }
        .store(in: &cancellables)
    }

    private func bindMicPublishers() {
        micClient.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$micReading)
        micClient.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$micReachable)
        // Derive activity + impact from each mic reading.
        micClient.$reading
            .receive(on: RunLoop.main)
            .sink { [weak self] reading in self?.ingestMic(reading) }
            .store(in: &cancellables)
    }

    private func bindLD2410Publishers() {
        ld2410Client.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$ld2410Reading)
        ld2410Client.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$ld2410Reachable)
    }

    // Mirror the LD2450 client's published state onto this view model.
    private func bindLD2450Publishers() {
        ld2450Client.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$ld2450Reading)
        ld2450Client.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$ld2450Reachable)
    }

    // Mirror the radar client's published state onto this view model so views
    // bound to `viewModel` re-render when the radar reading changes.
    private func bindRadarPublishers() {
        radarClient.$reading
            .receive(on: RunLoop.main)
            .assign(to: &$radarReading)
        radarClient.$isReachable
            .receive(on: RunLoop.main)
            .assign(to: &$radarReachable)
    }

    // MARK: - Binding via Combine sinks

    private func bindClientPublishers() {
        // Throttle WebSocket 10 Hz down to ~1.4 Hz — slow enough that big numbers
        // settle visually instead of twitching every tick.
        client.$snapshot
            .throttle(for: .milliseconds(700), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] snap in
                guard let self else { return }
                self.snapshot = snap
                self.updateLiveDataFlag(snap)
                if let v = snap?.vitalSigns { self.updateVitalHistory(v) }
                self.updateStablePersonCount(snap?.estimatedPersons)
                self.updateStablePresence(
                    presence: snap?.classification.presence,
                    motionLevel: snap?.classification.motionLevel
                )
                self.commitDisplayVitals(confidence: snap?.vitalSigns)
                self.sampleHistories(snap)
            }
            .store(in: &cancellables)

        client.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = connected
                if connected && !wasConnected {
                    self.connectedAt = Date()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                self.handleConnectionChange(connected: connected)
            }
            .store(in: &cancellables)

        client.$connectionError
            .receive(on: RunLoop.main)
            .assign(to: &$connectionError)

        client.$isSignalLost
            .receive(on: RunLoop.main)
            .assign(to: &$isSignalLost)
    }

    // MARK: - Connection grace period

    /// Debounce banner visibility so transient drops (<3.5s) don't flash UI noise.
    private func handleConnectionChange(connected: Bool) {
        disconnectGraceTask?.cancel()
        if connected {
            showDisconnectedBanner = false
        } else {
            disconnectGraceTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(disconnectGracePeriod * 1_000_000_000))
                if !Task.isCancelled && !self.isConnected {
                    self.showDisconnectedBanner = true
                }
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect(host: String) {
        client.connect(host: host)
        startPolling()
        // C6 (MR60BHA2) is a bedside VITALS sensor only. It never votes on
        // presence or count (that's LD2410C/LD2450) — it fabricates presence off
        // near-field static clutter. Its heart-rate/breathing are surfaced only
        // when the reading passes the clutter trust gate (C6RadarClient
        // .evaluateTrust); a phantom off furniture is rejected as "static
        // clutter" instead of shown as a fake pulse.
        radarClient.start(host: c6RadarHost)
        ld2450Client.start(host: ld2450Host)
        ld2410Client.start(host: ld2410Host)
        // The mic node was reflashed to the raw-audio streamer (no ESPHome HTTP),
        // so sound now comes from the Pi's voice-intelligence daemon over REST
        // (YAMNet + radar fusion), not the on-device loudness sensors.
        audioClient.start(host: host)   // Orange Pi :3025 /api/v1/audio
        hrClient.start(host: host)      // Orange Pi :3027 /api/v1/hr (BLE HR strap)
        countClient.start(host: host)   // Orange Pi :3028 /api/v1/count (CSI CNN)
    }

    func disconnect() {
        disconnectGraceTask?.cancel()
        showDisconnectedBanner = false
        client.disconnect()
        radarClient.stop()
        ld2450Client.stop()
        ld2410Client.stop()
        micClient.stop()
        audioClient.stop()
        hrClient.stop()
        countClient.stop()
        stopPolling()
        nodes = []
        zones = []
        adaptiveStatus = nil
        calibrationStatus = nil
        radarReading = nil
        radarReachable = false
        isConnected = false
        connectionError = nil
        isSignalLost = false
    }

    // MARK: - Polling

    private func startPolling() {
        startNodesPolling()
        startZonesPolling()
    }

    private func stopPolling() {
        nodesPollTask?.cancel()
        nodesPollTask = nil
        zonesPollTask?.cancel()
        zonesPollTask = nil
    }

    private func startNodesPolling() {
        nodesPollTask?.cancel()
        let interval = nodesPollIntervalSeconds
        nodesPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNodes()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func startZonesPolling() {
        zonesPollTask?.cancel()
        let interval = zonesPollIntervalSeconds
        zonesPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshZones()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    // MARK: - Data refresh

    func refreshNodes() async {
        nodesLoading = true
        nodesError = nil
        do {
            let response = try await client.fetchNodes()
            nodes = response.nodes
            nodesError = nil
        } catch {
            nodesError = userFriendlyError(error)
        }
        nodesLoading = false
    }

    func refreshZones() async {
        zonesLoading = true
        zonesError = nil
        do {
            let response = try await client.fetchZones()
            zones = response.zones
                .sorted { $0.key < $1.key }
                .map { ZoneInfo(name: $0.key, personCount: $0.value.personCount, status: $0.value.status) }
            zonesError = nil
        } catch {
            zonesError = userFriendlyError(error)
        }
        zonesLoading = false
    }

    func refreshAdaptiveStatus() async {
        do {
            adaptiveStatus = try await client.fetchAdaptiveStatus()
        } catch {
            // Non-critical
        }
    }

    func refreshCalibrationStatus() async {
        do {
            calibrationStatus = try await client.fetchCalibrationStatus()
        } catch {
            // Non-critical
        }
    }

    // MARK: - Derived computed properties

    /// Authoritative occupant count for the Occupancy hero. The LD2450 radar
    /// gives a true multi-target count, so prefer it when reachable; it reads
    /// 0 whenever no one is in view (absent → 0 automatically). Falls back to
    /// the server's hysteresis-stabilized count when the radar is offline.
    var radarOccupantCount: Int { fusedOccupantCount }

    /// True while a live occupant count is coming from any radar source.
    var radarCountIsLive: Bool {
        (ld2450Reachable && ld2450Reading != nil)
            || (ld2410Reachable && ld2410Reading != nil)
    }

    // MARK: - Sensor fusion
    //
    // Stitch the radars into one coherent room picture. Each sensor is trusted
    // ONLY for what it does well:
    //   • LD2450 gives the authoritative multi-target count + position.
    //   • LD2410C keeps the room "occupied" when the LD2450 drops a still person.
    //   • C6 (60 GHz) contributes VITALS ONLY — never presence or count. It's a
    //     bedside sensor that fabricates presence off static clutter, so letting
    //     it vote on occupancy is exactly what created the phantom count. Its
    //     vitals are gated behind the clutter trust check (vitalsTrusted).

    /// Any live sensor currently sees a person. The LD2450 only contributes
    /// once its antenna is attached (otherwise its ghost targets would fake
    /// presence in an empty room). The C6 is deliberately excluded — see above.
    var anyPresenceEvidence: Bool {
        if ld2450AntennaConnected, ld2450Reachable, (ld2450Reading?.targetCount ?? 0) > 0 { return true }
        if ld2410Reachable, ld2410Reading?.isTrustworthyPresence == true { return true }
        return false
    }

    /// Fused occupant count. Trust the LD2450's true multi-target count only
    /// when its antenna is attached; until then it hallucinates ghosts, so the
    /// count comes from the single-occupancy LD2410C (0 or 1). The C6 never
    /// contributes to the count. Server count is the last-resort fallback.
    var fusedOccupantCount: Int {
        if ld2450AntennaConnected, ld2450Reachable, let r = ld2450Reading {
            if r.targetCount > 0 { return r.targetCount }
            return anyPresenceEvidence ? 1 : 0
        }
        // LD2410C is single-occupancy: 0 or 1, no ghosts.
        if ld2410Reachable {
            return anyPresenceEvidence ? 1 : 0
        }
        // No direct sensors reachable — fall back to the server's count.
        return personCount
    }

    /// Live heart rate. Priority: a BLE HR strap/ring (contact, accurate) →
    /// the C6 radar (only when it passes the clutter trust gate) → the
    /// (possibly stale) server-derived value.
    var fusedHeartRate: Int? {
        if bleHrReachable, bleHeartReading?.isLive == true, let bpm = bleHeartReading?.bpm, bpm > 0 {
            return bpm
        }
        if radarReachable, radarReading?.vitalsTrusted == true,
           let hr = radarReading?.heartRateBpm, hr > 0 {
            return Int(hr.rounded())
        }
        return displayHeartRate
    }

    /// Heart-rate variability (RMSSD, ms) — only the BLE strap provides it.
    var fusedHrvMs: Double? {
        guard bleHrReachable, bleHeartReading?.isLive == true else { return nil }
        return bleHeartReading?.hrvMs
    }

    /// Which source is currently feeding the heart rate (for honest labeling).
    var heartRateSource: String? {
        if bleHrReachable, bleHeartReading?.isLive == true { return "BLE strap" }
        if radarReachable, radarReading?.vitalsTrusted == true, (radarReading?.heartRateBpm ?? 0) > 0 { return "60 GHz radar" }
        return nil
    }

    /// Live breathing rate — C6 when trusted, else server fallback.
    var fusedBreathingRate: Int? {
        if radarReachable, radarReading?.vitalsTrusted == true,
           let br = radarReading?.breathingRateBpm, br > 0 {
            return Int(br.rounded())
        }
        return displayBreathingRate
    }

    var personCount: Int {
        // Defensive consistency clamp: if classification.presence is explicitly
        // false, the count MUST be 0. Prevents the "1 Person detected" /
        // "Presence: Not detected" contradiction the user caught on 2026-06-16
        // (server-side fix is in main.rs::apply_radar_override layer 2; this is
        // belt-and-suspenders for any edge case that slips through).
        if let presence = snapshot?.classification.presence, !presence {
            return 0
        }
        // Use hysteresis-stabilized count so the big number doesn't flicker.
        return displayPersonCount
    }

    var motionLevel: String {
        snapshot?.classification.motionLevel ?? "absent"
    }

    var motionLevelDisplay: String {
        motionLevel.motionLevelDisplay
    }

    /// Motion level shown next to the sticky presence indicator. While the
    /// room is held "Present" (10s hysteresis), brief "absent" motion blips
    /// are upgraded to "present_still" so the detail row matches the hero.
    var stickyMotionLevelDisplay: String {
        if displayPresence && motionLevel == "absent" {
            return "Present still".replacingOccurrences(of: "_", with: " ")
        }
        return motionLevel.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var overallConfidence: Double {
        snapshot?.classification.confidence ?? 0.0
    }

    var motionColor: Color {
        switch motionLevel {
        case "absent":          return .healthSub
        case "present_still":   return .steel
        case "present_moving":  return .orange
        case "active":          return .red
        default:                return .healthSub
        }
    }

    // ── Fused motion — OWNED by the LD2410C ──────────────────────────────────
    // The LD2410C reliably reports moving/still out to ~3.7 m+, where the LD2450
    // goes blind (~2 m) and the server has no radar since the C6 was pulled. So
    // the ranged LD2410 is the honest motion source; server classification is a
    // last-resort fallback. (Roles: LD2410C = presence+motion, LD2450 = count+where.)
    var fusedMotionState: String {   // "moving" | "still" | "absent"
        if ld2410Reachable, let r = ld2410Reading, r.isTrustworthyPresence {
            if r.movingPresent { return "moving" }
            if r.stillPresent { return "still" }
        }
        if anyPresenceEvidence { return "still" }   // present but no motion flag → still
        return motionLevel.contains("moving") ? "moving"
             : motionLevel.contains("still") ? "still" : "absent"
    }
    var fusedMotionDisplay: String {
        switch fusedMotionState {
        case "moving": return "Moving"
        case "still":  return "Still"
        default:       return "No motion"
        }
    }
    var fusedMotionColor: Color {
        switch fusedMotionState {
        case "moving": return .orange
        case "still":  return .steel
        default:       return .healthSub
        }
    }

    // ── Direct-sensor truth (the server snapshot is starved — C6 bridge off,
    // LD2450/LD2410/mic not server-ingested — so every panel must read the
    // direct sensors, the same source Node Health uses). ──────────────────────
    /// Someone is present per the radars (same source as the count hero).
    var fusedPresent: Bool { anyPresenceEvidence }
    /// Live direct-poll nodes (LD2450 + LD2410C + mic audio stream + C6 vitals).
    var directActiveNodes: Int {
        (ld2450Reachable ? 1 : 0)
            + (ld2410Reachable ? 1 : 0)
            + ((audioReachable && audioReading?.stream == "up") ? 1 : 0)
            + (radarReachable ? 1 : 0)
    }
    /// True when any direct sensor is delivering live data.
    var directDataLive: Bool {
        ld2450Reachable || ld2410Reachable || (audioReachable && audioReading?.stream == "up") || radarReachable
    }

    var isDemoMode: Bool {
        snapshot?.source == "simulate"
    }

    var sourceLabel: String {
        isDemoMode ? "Demo" : "Live"
    }

    var formattedTick: String {
        guard let tick = snapshot?.tick else { return "–" }
        return "#\(tick)"
    }

    // MARK: - Signal health (green / yellow / red stoplight)

    /// A caregiver-friendly summary of the data feed's health. The "Last tick"
    /// counter was a developer artefact; this is what a clinician/family
    /// member actually needs: am I getting trustworthy live data right now?
    enum SignalHealth {
        case green       // fresh data flowing, recent unique tick, WS connected
        case yellow      // connected but data slowing / verifying / demo
        case red         // disconnected, signal lost, or stuck > staleThreshold

        var label: String {
            switch self {
            case .green:  return "Live"
            case .yellow: return "Verifying"
            case .red:    return "Signal lost"
            }
        }

        var subtitle: String {
            switch self {
            case .green:  return "Real-time data flowing"
            case .yellow: return "Data slowing — may be transitioning"
            case .red:    return "No fresh data from the hub"
            }
        }

        /// SF Symbols glyph paired with the colour.
        var systemImage: String {
            switch self {
            case .green:  return "checkmark.circle.fill"
            case .yellow: return "exclamationmark.triangle.fill"
            case .red:    return "xmark.octagon.fill"
            }
        }
    }

    /// Derived from existing telemetry — no new wiring needed.
    var signalHealth: SignalHealth {
        // Live direct-sensor data is the real "healthy" signal now that the
        // server snapshot is starved — trust it first.
        if directDataLive { return .green }
        if !isConnected || connectionError != nil { return .red }
        if isSignalLost                            { return .red }
        if isDemoMode || !isLiveDataFlowing        { return .yellow }
        return .green
    }

    // MARK: - Vital signs display

    var isMeasuring: Bool {
        guard let connectedAt else { return true }
        return Date().timeIntervalSince(connectedAt) < 30
    }

    /// State for a vital sign display, returned by helpers below.
    enum VitalDisplay {
        case live(value: Int)              // confidence ≥ 0.6, in physiologic range
        case approximate(value: Int)       // confidence 0.3–0.6, in physiologic range
        case held(value: Int, age: TimeInterval) // failure — showing last good value
        case unavailable                   // failure and no known good value

        var text: String {
            switch self {
            case .live(let v):        return "\(v)"
            case .approximate(let v): return "~\(v)"
            case .held(let v, _):     return "\(v)"
            case .unavailable:        return "–"
            }
        }
        var isHeld: Bool {
            if case .held = self { return true } else { return false }
        }
        var heldAge: TimeInterval? {
            if case .held(_, let age) = self { return age } else { return nil }
        }
    }

    /// Direction-of-change indicator for a vital, compared to ~30s ago.
    enum VitalTrend {
        case rising(delta: Int)
        case falling(delta: Int)
        case steady

        var icon: String {
            switch self {
            case .rising:  return "arrow.up.right"
            case .falling: return "arrow.down.right"
            case .steady:  return "arrow.right"
            }
        }

        var description: String {
            switch self {
            case .rising(let d):  return "+\(d) vs 30s ago"
            case .falling(let d): return "−\(d) vs 30s ago"
            case .steady:         return "Steady"
            }
        }

        var isMeaningful: Bool {
            switch self {
            case .steady: return false
            default:      return true
            }
        }
    }

    func heartRateTrend() -> VitalTrend {
        computeTrend(history: heartRateHistory)
    }

    func breathingTrend() -> VitalTrend {
        computeTrend(history: breathingHistory)
    }

    /// Compare the latest sample with the value ~30 samples back (≈30 s at 1 Hz).
    /// Returns `.steady` if the difference is < 2 units or history is too short.
    private func computeTrend(history: [Double]) -> VitalTrend {
        guard history.count >= 8 else { return .steady }
        let lookback = min(30, history.count - 1)
        let current = history.last!
        let past = history[history.count - 1 - lookback]
        let delta = current - past
        let absDelta = Int(abs(delta).rounded())
        if absDelta < 2 { return .steady }
        return delta > 0 ? .rising(delta: absDelta) : .falling(delta: absDelta)
    }

    func heartRateDisplay(vitals: VitalSigns) -> VitalDisplay {
        vitalDisplay(
            current: displayHeartRate,
            confidence: vitals.heartbeatConfidence,
            plausible: heartRatePlausibleRange,
            heldValue: lastGoodHeartRate,
            heldAt: lastGoodHeartRateAt
        )
    }

    func breathingDisplay(vitals: VitalSigns) -> VitalDisplay {
        vitalDisplay(
            current: displayBreathingRate,
            confidence: vitals.breathingConfidence,
            plausible: breathingRatePlausibleRange,
            heldValue: lastGoodBreathingRate,
            heldAt: lastGoodBreathingRateAt
        )
    }

    private func vitalDisplay(
        current: Int?,
        confidence: Double,
        plausible: ClosedRange<Int>,
        heldValue: Int?,
        heldAt: Date?
    ) -> VitalDisplay {
        let currentInRange = current.map { plausible.contains($0) } ?? false

        if confidence >= 0.6, let v = current, currentInRange {
            return .live(value: v)
        }
        if confidence >= 0.3, let v = current, currentInRange {
            return .approximate(value: v)
        }
        // Failure path — never show "—" if we have any value to fall back to.
        // 1) Prefer the last high-confidence in-range value.
        if let held = heldValue, let at = heldAt {
            let age = Date().timeIntervalSince(at)
            if age <= heldValueMaxAge {
                return .held(value: held, age: age)
            }
        }
        // 2) Otherwise hold the most recent stabilized display value.
        if let v = current, plausible.contains(v) {
            return .held(value: v, age: 0)
        }
        // 3) Only show "unavailable" before the very first valid sample.
        return .unavailable
    }

    // Kept for callers that just need a string (e.g., older code paths).
    func formattedHeartRate(vitals: VitalSigns) -> String {
        heartRateDisplay(vitals: vitals).text
    }
    func formattedBreathing(vitals: VitalSigns) -> String {
        breathingDisplay(vitals: vitals).text
    }

    /// Apply hysteresis: only update the visible integer when the EMA has moved
    /// past the previous boundary by `hysteresisMargin`. Stops boundary flicker.
    private func commitDisplayVitals(confidence vitals: VitalSigns?) {
        if let target = emaHeartRate {
            displayHeartRate = applyHysteresis(current: displayHeartRate, target: target)
        }
        if let target = emaBreathing {
            displayBreathingRate = applyHysteresis(current: displayBreathingRate, target: target)
        }
        if let vitals { updateLastGoodVitals(vitals) }
    }

    /// Promote the current display value to "last known good" when confidence is
    /// high AND the value is in the physiologic range.
    private func updateLastGoodVitals(_ vitals: VitalSigns) {
        let now = Date()
        if vitals.heartbeatConfidence >= goodSampleConfidence,
           let hr = displayHeartRate,
           heartRatePlausibleRange.contains(hr) {
            lastGoodHeartRate = hr
            lastGoodHeartRateAt = now
        }
        if vitals.breathingConfidence >= goodSampleConfidence,
           let br = displayBreathingRate,
           breathingRatePlausibleRange.contains(br) {
            lastGoodBreathingRate = br
            lastGoodBreathingRateAt = now
        }
    }

    private func applyHysteresis(current: Int?, target: Double) -> Int {
        guard let current else { return Int(target.rounded()) }
        let diff = target - Double(current)
        if abs(diff) >= hysteresisMargin {
            return Int(target.rounded())
        }
        return current
    }

    private func updateStablePersonCount(_ incoming: Int?) {
        guard let value = incoming else { return }
        if value == pendingPersonCount {
            pendingPersonCountStreak += 1
        } else {
            pendingPersonCount = value
            pendingPersonCountStreak = 1
        }
        // Commit only after N consecutive identical readings.
        if pendingPersonCountStreak >= personCountStabilityFrames,
           value != displayPersonCount {
            displayPersonCount = value
        }
    }

    /// Sticky binary presence. Logic:
    ///   - presence=true OR motion != "absent" → evidence of a person; refresh
    ///     the timestamp and force display=Present immediately.
    ///   - presence=false AND motion == "absent" → only commit display=Empty
    ///     after `presenceStickyDuration` of *continuous* such evidence.
    /// This handles the elder-care case where the person is sitting still
    /// (presence flag may flicker, motion may briefly read absent) without
    /// reporting them as having left the room.
    private func updateStablePresence(presence: Bool?, motionLevel: String?) {
        let pres = presence ?? false
        let motion = motionLevel ?? "absent"
        // Include the direct radars so the server path can't clear presence
        // while a sensor still sees someone (server is starved).
        let hasEvidence = pres || motion != "absent" || anyPresenceEvidence

        // Record the transition + sample for the timeline strip.
        let beforeDisplay = displayPresence

        if hasEvidence {
            lastEvidenceOfPresenceAt = Date()
            lastTimePresent = Date()
            if !displayPresence { displayPresence = true }
        } else if let last = lastEvidenceOfPresenceAt,
                  Date().timeIntervalSince(last) >= presenceStickyDuration,
                  displayPresence {
            displayPresence = false
        } else if lastEvidenceOfPresenceAt == nil, displayPresence {
            displayPresence = false
        }

        if displayPresence != beforeDisplay {
            presenceChangedAt = Date()
        }
        recordPresenceSample(present: displayPresence)
    }

    /// Append a presence sample. We sample on every state change AND at
    /// most every 30 s when state is unchanged. Bounded to 24 h.
    private var lastPresenceSampleAt: Date = .distantPast
    private func recordPresenceSample(present: Bool) {
        let now = Date()
        let last = presenceHistory.last
        let mustRecord = (last?.present != present)
            || now.timeIntervalSince(lastPresenceSampleAt) >= 30
        guard mustRecord else { return }
        presenceHistory.append(PresenceSample(at: now, present: present))
        lastPresenceSampleAt = now
        // Trim older than 24 h.
        let cutoff = now.addingTimeInterval(-presenceHistoryRetention)
        if let firstKeepIndex = presenceHistory.firstIndex(where: { $0.at >= cutoff }),
           firstKeepIndex > 0 {
            presenceHistory.removeFirst(firstKeepIndex)
        }
    }

    // MARK: - Caregiver-facing labels (time-in-state + last seen)

    /// Examples:  "Present for 12 min"  ·  "Empty for 47 min"  ·  "Just arrived"
    var timeInStateLabel: String {
        let elapsed = Date().timeIntervalSince(presenceChangedAt)
        let stateWord = displayPresence ? "Present" : "Empty"
        if elapsed < 60 { return "\(stateWord) · just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(stateWord) for \(minutes) min" }
        let hours = minutes / 60
        let remMin = minutes % 60
        if remMin == 0 { return "\(stateWord) for \(hours) h" }
        return "\(stateWord) for \(hours) h \(remMin) m"
    }

    /// Only meaningful when empty — what time the room last had someone.
    /// Returns nil if we've never seen anyone (no history yet).
    var lastSeenLabel: String? {
        guard !displayPresence, let last = lastTimePresent else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return "Last seen \(fmt.string(from: last))"
    }

    private func updateVitalHistory(_ vitals: VitalSigns) {
        let a = emaAlpha
        // Gate EMA updates on minimum confidence AND a non-nil sample —
        // the server sends nil HR/BR while no person is tracked.
        if vitals.heartbeatConfidence >= 0.3, let hr = vitals.heartRateBpm {
            emaHeartRate = emaHeartRate.map { a * hr + (1 - a) * $0 } ?? hr
        }
        if vitals.breathingConfidence >= 0.3, let br = vitals.breathingRateBpm {
            emaBreathing = emaBreathing.map { a * br + (1 - a) * $0 } ?? br
        }
    }

    private func sampleHistories(_ snapshot: SensingSnapshot?) {
        let now = Date()
        guard now.timeIntervalSince(lastHistorySample) >= 1.0 else { return }
        lastHistorySample = now

        if let hr = emaHeartRate {
            heartRateHistory.append(hr)
            if heartRateHistory.count > historyLength { heartRateHistory.removeFirst() }
        }
        if let br = emaBreathing {
            breathingHistory.append(br)
            if breathingHistory.count > historyLength { breathingHistory.removeFirst() }
        }
        if let count = snapshot?.estimatedPersons {
            personCountHistory.append(Double(count))
            if personCountHistory.count > historyLength { personCountHistory.removeFirst() }
        }
        if let features = snapshot?.nodeFeatures {
            for nf in features {
                var arr = nodeRssiHistory[nf.nodeId] ?? []
                arr.append(nf.rssiDbm)
                if arr.count > historyLength { arr.removeFirst() }
                nodeRssiHistory[nf.nodeId] = arr
            }
        }
    }

    private func updateLiveDataFlag(_ snapshot: SensingSnapshot?) {
        let now = Date()
        if let tick = snapshot?.tick, tick != lastTickValue {
            lastTickValue = tick
            lastTickChangeAt = now
            if !isLiveDataFlowing { isLiveDataFlowing = true }
        } else if now.timeIntervalSince(lastTickChangeAt) > 1.5 && isLiveDataFlowing {
            isLiveDataFlowing = false
        }
    }

    // MARK: - Node helpers

    func rssiBarCount(rssi: Double) -> Int {
        if rssi > -50 { return 4 }
        if rssi > -65 { return 3 }
        if rssi > -75 { return 2 }
        if rssi > -85 { return 1 }
        return 0
    }

    func isNodeStale(_ node: NodeStatus) -> Bool {
        node.lastSeenMs > 2000
    }

    // MARK: - Zone helpers

    func zoneColor(personCount: Int) -> Color {
        switch personCount {
        case 0:     return Color.steelPale
        case 1:     return Color.steel.opacity(0.22)
        default:    return Color.steel.opacity(0.52)
        }
    }

    // MARK: - Error helper

    private func userFriendlyError(_ error: Error) -> String {
        if let ruViewError = error as? RuViewError {
            return ruViewError.errorDescription ?? "Unknown error"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "No internet connection"
            case .timedOut: return "Request timed out"
            case .cannotConnectToHost: return "Cannot reach server"
            default: return "Network error"
            }
        }
        return "Something went wrong"
    }
}
