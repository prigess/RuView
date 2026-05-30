import SwiftUI
import Combine

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

    // MARK: - Polling tasks
    private var nodesPollTask: Task<Void, Never>?
    private var zonesPollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(client: RuViewClient = RuViewClient()) {
        self.client = client
        bindClientPublishers()
    }

    // MARK: - Binding via Combine sinks

    private func bindClientPublishers() {
        // Mirror all published properties from client → self
        // Both are @MainActor so this is safe
        client.$snapshot
            .receive(on: RunLoop.main)
            .assign(to: &$snapshot)

        client.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = connected
                if connected && !wasConnected {
                    self.connectedAt = Date()
                }
            }
            .store(in: &cancellables)

        client.$connectionError
            .receive(on: RunLoop.main)
            .assign(to: &$connectionError)

        client.$isSignalLost
            .receive(on: RunLoop.main)
            .assign(to: &$isSignalLost)
    }

    // MARK: - Connect / Disconnect

    func connect(host: String) {
        client.connect(host: host)
        startPolling()
    }

    func disconnect() {
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
        snapshot?.estimatedPersons ?? 0
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
        case "absent":          return .gray
        case "present_still":  return .blue
        case "present_moving": return .orange
        case "active":         return .red
        default:               return .gray
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

    func formattedHeartRate(vitals: VitalSigns) -> String {
        formattedVital(value: vitals.heartRateBpm, confidence: vitals.heartbeatConfidence)
    }

    func formattedBreathing(vitals: VitalSigns) -> String {
        formattedVital(value: vitals.breathingRateBpm, confidence: vitals.breathingConfidence)
    }

    private func formattedVital(value: Double, confidence: Double) -> String {
        if confidence < 0.3 {
            return "–"
        } else if confidence < 0.6 {
            return "~\(String(format: "%.0f", value))"
        } else {
            return String(format: "%.0f", value)
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
        case 0: return Color(.systemGray5)
        case 1: return .blue.opacity(0.3)
        default: return .orange.opacity(0.4)
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
