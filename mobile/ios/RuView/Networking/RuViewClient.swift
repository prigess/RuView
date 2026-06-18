import Foundation
import UIKit

// MARK: - RuViewClient

@MainActor
final class RuViewClient: ObservableObject {

    // MARK: Published state
    @Published var snapshot: SensingSnapshot?
    @Published var isConnected: Bool = false
    @Published var connectionError: String?

    // MARK: Private state
    private var host: String = ""
    private var wsTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var backoffDelay: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0
    private var isDisconnecting = false

    // Stale detection — when only the C6 is streaming (~1 Hz MQTT-driven),
    // the server re-broadcasts the same tick value ~10× before a fresh
    // source frame increments it. Counting "unchanged ticks" is therefore
    // useless; we instead track wall-clock time since the last *unique*
    // tick value and only declare signal-lost if no new tick arrived for
    // `staleThresholdSeconds`.
    private var lastTickSeen: Int = -1
    private var lastUniqueTickAt: Date = Date()
    private let staleThresholdSeconds: TimeInterval = 3.0
    @Published var isSignalLost: Bool = false

    // Publish throttle — server emits at 10 Hz, but UI doesn't need that.
    // We always decode every frame (to keep TCP receive draining) but only
    // assign to @Published at most every `publishMinIntervalMs` to avoid
    // thrashing MainActor with 10 SwiftUI re-renders per second.
    private var lastPublishedAt: Date = .distantPast
    private let publishMinIntervalMs: Double = 200  // ≈5 Hz UI updates

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: config)
        setupAppLifecycleObservers()
    }

    // MARK: - Connect / Disconnect

    func connect(host: String) {
        guard !host.isEmpty else { return }
        // Same host + already connected: idempotent, skip.
        if host == self.host, wsTask != nil { return }
        self.host = host
        isDisconnecting = false
        backoffDelay = 1.0
        cancelReconnect()
        closeWebSocket()
        openWebSocket()
    }

    func disconnect() {
        isDisconnecting = true
        cancelReconnect()
        closeWebSocket()
        isConnected = false
        connectionError = nil
    }

    // MARK: - WebSocket lifecycle

    private func openWebSocket() {
        guard !host.isEmpty, !isDisconnecting else { return }
        guard let url = URL(string: "ws://\(host):3023/ws/sensing") else {
            connectionError = "Invalid server address"
            return
        }

        // Always tear down any prior task before opening a new one — the
        // reconnect path bypasses connect(host:), so the only safe place
        // to enforce single-socket invariant is here.
        closeWebSocket()

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        wsTask = urlSession.webSocketTask(with: request)
        wsTask?.resume()
        scheduleReceive()
    }

    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func scheduleReceive() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        guard let task = wsTask else { return }
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleRawMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleRawMessage(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            if !isDisconnecting {
                isConnected = false
                connectionError = friendlyError(error)
                scheduleReconnect()
            }
        }
    }

    private func handleRawMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        do {
            let parsed = try decoder.decode(SensingSnapshot.self, from: data)
            // Connection liveness is updated on every frame so the
            // "connected" indicator reacts immediately — but the heavier
            // @Published snapshot (which triggers SwiftUI tree updates)
            // is rate-limited to keep MainActor responsive.
            if !isConnected {
                isConnected = true
                connectionError = nil
            }
            backoffDelay = 1.0
            checkStaleness(tick: parsed.tick)
            let now = Date()
            if now.timeIntervalSince(lastPublishedAt) * 1000 >= publishMinIntervalMs {
                snapshot = parsed
                lastPublishedAt = now
            }
        } catch {
            // Decode failure means the wire schema drifted from the iOS
            // model — log it so the next mismatch isn't silent.
            NSLog("RuView WS decode failed: %@; sample=%@",
                  String(describing: error),
                  String(text.prefix(200)))
        }
    }

    private func checkStaleness(tick: Int) {
        if tick != lastTickSeen {
            lastTickSeen = tick
            lastUniqueTickAt = Date()
            if isSignalLost { isSignalLost = false }
        } else {
            // Duplicate tick. Only flag stale once we haven't seen a new
            // tick value for the full threshold — accommodates low-rate
            // sources like C6 MQTT (~1 Hz) without false-positive lost.
            if Date().timeIntervalSince(lastUniqueTickAt) >= staleThresholdSeconds {
                if !isSignalLost { isSignalLost = true }
            }
        }
    }

    // MARK: - Reconnect with exponential backoff

    private func scheduleReconnect() {
        guard !isDisconnecting else { return }
        cancelReconnect()
        let delay = backoffDelay
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !self.isDisconnecting else { return }
            await self.openWebSocket()
        }
        backoffDelay = min(backoffDelay * 2, maxBackoff)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - App lifecycle

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleBackground()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleForeground()
            }
        }
    }

    private func handleBackground() {
        closeWebSocket()
        cancelReconnect()
    }

    private func handleForeground() {
        guard !isDisconnecting, !host.isEmpty else { return }
        backoffDelay = 1.0
        openWebSocket()
    }

    // MARK: - REST helpers

    private func baseURL() -> String {
        "http://\(host):3022"
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: baseURL() + path) else {
            throw RuViewError.invalidURL
        }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuViewError.serverError
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any] = [:], as type: T.Type) async throws -> T {
        guard let url = URL(string: baseURL() + path) else {
            throw RuViewError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuViewError.serverError
        }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - REST fetch functions

    func checkHealth() async throws -> HealthResponse {
        try await get("/health", as: HealthResponse.self)
    }

    func fetchNodes() async throws -> NodesResponse {
        try await get("/api/v1/nodes", as: NodesResponse.self)
    }

    func fetchZones() async throws -> ZoneSummaryResponse {
        try await get("/api/v1/pose/zones/summary", as: ZoneSummaryResponse.self)
    }

    func fetchVitalSigns() async throws -> VitalSignsResponse {
        try await get("/api/v1/vital-signs", as: VitalSignsResponse.self)
    }

    func fetchAdaptiveStatus() async throws -> AdaptiveStatus {
        try await get("/api/v1/adaptive/status", as: AdaptiveStatus.self)
    }

    func fetchCalibrationStatus() async throws -> CalibrationStatus {
        try await get("/api/v1/calibration/status", as: CalibrationStatus.self)
    }

    // MARK: - REST action functions

    func startCalibration() async throws -> Bool {
        let result = try await post("/api/v1/calibration/start", body: [:], as: BoolResponse.self)
        return result.success
    }

    func stopCalibration() async throws -> Bool {
        let result = try await post("/api/v1/calibration/stop", as: BoolResponse.self)
        return result.success
    }

    func startRecording(name: String) async throws -> String {
        let result = try await post("/api/v1/recording/start", body: ["id": name], as: BoolResponse.self)
        guard result.success else { throw RuViewError.serverError }
        return result.recordingId ?? name
    }

    func stopRecording() async throws -> Bool {
        let result = try await post("/api/v1/recording/stop", as: BoolResponse.self)
        return result.success
    }

    func retrainClassifier() async throws -> BoolResponse {
        try await post("/api/v1/adaptive/train", body: [:], as: BoolResponse.self)
    }

    func setGroundTruth(_ count: Int) async throws -> BoolResponse {
        try await post("/api/v1/config/ground-truth", body: ["count": count], as: BoolResponse.self)
    }

    // MARK: - Error helpers

    private func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection"
            case .timedOut:
                return "Connection timed out"
            case .cannotConnectToHost:
                return "Cannot reach server"
            case .networkConnectionLost:
                return "Connection lost"
            default:
                return "Network error"
            }
        }
        return "Connection failed"
    }
}

// MARK: - Error types

enum RuViewError: LocalizedError {
    case invalidURL
    case serverError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server address"
        case .serverError: return "Server returned an error"
        case .decodingError: return "Unexpected data from server"
        }
    }
}
