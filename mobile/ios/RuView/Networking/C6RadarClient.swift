import Foundation

// MARK: - C6RadarReading

struct C6RadarReading {
    let heartRateBpm: Double?      // nil when radar reports no target
    let breathingRateBpm: Double?  // nil when radar reports no target
    let targetDistanceCm: Double?  // nil when no target
    let personPresent: Bool
    let wifiRssiDbm: Double?
    let timestamp: Date

    var hasVitals: Bool {
        (heartRateBpm ?? 0) > 0 || (breathingRateBpm ?? 0) > 0
    }
}

// MARK: - C6RadarClient
//
// Polls the ESPHome HTTP/JSON endpoints exposed by the ESP32-C6 radar node.
// The C6 publishes:
//   /sensor/heart_rate          {"value": 72.0,  "state": "72 BPM"}  | value:null when no target
//   /sensor/breath_rate         {"value": 18.0,  "state": "18 BPM"}  | value:null
//   /sensor/target_distance     {"value": 145.0, "state": "145 cm"}  | value:null
//   /sensor/wifi_rssi           {"value": -58,   "state": "-58 dBm"}
//   /binary_sensor/person_present {"value": true, "state": "ON"}
//
// We treat any HTTP failure as "unreachable" — the SensingViewModel will hide
// the radar card. Polling cadence is conservative (1.5s) because the radar
// itself updates ~1 Hz internally.

@MainActor
final class C6RadarClient: ObservableObject {

    @Published var reading: C6RadarReading?
    @Published var isReachable: Bool = false
    @Published var lastErrorMessage: String?

    private var host: String = ""
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession

    private let pollInterval: TimeInterval = 1.5
    private var consecutiveFailures: Int = 0
    private let reachableMaxFailures: Int = 2

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true
        self.urlSession = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    func start(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pollTask != nil && trimmed == self.host { return }
        stop()
        self.host = trimmed
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isReachable = false
        reading = nil
        consecutiveFailures = 0
    }

    // MARK: - Polling loop

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty else { return }
        async let hr      = fetchNumeric("/sensor/heart_rate")
        async let br      = fetchNumeric("/sensor/breath_rate")
        async let dist    = fetchNumeric("/sensor/target_distance")
        async let rssi    = fetchNumeric("/sensor/wifi_rssi")
        async let present = fetchBool("/binary_sensor/person_present")

        let hrRes      = await hr
        let brRes      = await br
        let distRes    = await dist
        let rssiRes    = await rssi
        let presentRes = await present

        // If everything failed, mark unreachable after a couple of misses.
        let allFailed = hrRes.failed && brRes.failed && distRes.failed
            && rssiRes.failed && presentRes.failed
        if allFailed {
            consecutiveFailures += 1
            if consecutiveFailures >= reachableMaxFailures {
                isReachable = false
                reading = nil
            }
            return
        }

        consecutiveFailures = 0
        isReachable = true
        lastErrorMessage = nil
        reading = C6RadarReading(
            heartRateBpm:      hrRes.value,
            breathingRateBpm:  brRes.value,
            targetDistanceCm:  distRes.value,
            personPresent:     presentRes.bool ?? false,
            wifiRssiDbm:       rssiRes.value,
            timestamp:         Date()
        )
    }

    // MARK: - HTTP helpers

    private struct NumericResult {
        let value: Double?   // nil when ESPHome returned `value: null`
        let failed: Bool     // true on HTTP/network/parse error
    }

    private struct BoolResult {
        let bool: Bool?
        let failed: Bool
    }

    private struct ESPHomeSensor: Decodable {
        let value: Double?
    }

    private struct ESPHomeBinarySensor: Decodable {
        let value: Bool?
    }

    private func fetchNumeric(_ path: String) async -> NumericResult {
        guard let url = URL(string: "http://\(host)\(path)") else {
            return NumericResult(value: nil, failed: true)
        }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return NumericResult(value: nil, failed: true)
            }
            let decoded = try JSONDecoder().decode(ESPHomeSensor.self, from: data)
            return NumericResult(value: decoded.value, failed: false)
        } catch {
            return NumericResult(value: nil, failed: true)
        }
    }

    private func fetchBool(_ path: String) async -> BoolResult {
        guard let url = URL(string: "http://\(host)\(path)") else {
            return BoolResult(bool: nil, failed: true)
        }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return BoolResult(bool: nil, failed: true)
            }
            let decoded = try JSONDecoder().decode(ESPHomeBinarySensor.self, from: data)
            return BoolResult(bool: decoded.value, failed: false)
        } catch {
            return BoolResult(bool: nil, failed: true)
        }
    }
}
