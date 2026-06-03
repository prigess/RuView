import SwiftUI
import Combine
import UIKit

// MARK: - SensingViewModel

@MainActor
final class SensingViewModel: ObservableObject {

    // MARK: - The underlying client (exposed for direct use in wizard)
    let client: RuViewClient

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
    private var nodesPollTask: Task<Void, Never>?
    private var zonesPollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        self.client = RuViewClient()
        bindClientPublishers()
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
    }

    func disconnect() {
        disconnectGraceTask?.cancel()
        showDisconnectedBanner = false
        client.disconnect()
        stopPolling()
        nodes = []
        zones = []
        adaptiveStatus = nil
        calibrationStatus = nil
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
        nodesPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNodes()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func startZonesPolling() {
        zonesPollTask?.cancel()
        zonesPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshZones()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    var personCount: Int {
        // Use hysteresis-stabilized count so the big number doesn't flicker.
        displayPersonCount
    }

    var motionLevel: String {
        snapshot?.classification.motionLevel ?? "absent"
    }

    var motionLevelDisplay: String {
        motionLevel.motionLevelDisplay
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

    private func updateVitalHistory(_ vitals: VitalSigns) {
        let a = emaAlpha
        // Gate EMA updates on minimum confidence — prevents garbage samples
        // from polluting the smoothed value during failures so the held value
        // we eventually show is the real last-good reading, not noise drift.
        if vitals.heartbeatConfidence >= 0.3 {
            emaHeartRate = emaHeartRate.map { a * vitals.heartRateBpm + (1 - a) * $0 } ?? vitals.heartRateBpm
        }
        if vitals.breathingConfidence >= 0.3 {
            emaBreathing = emaBreathing.map { a * vitals.breathingRateBpm + (1 - a) * $0 } ?? vitals.breathingRateBpm
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
