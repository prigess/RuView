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

// MARK: - LD2450 (24 GHz multi-target tracking radar)

/// One tracked target from the LD2450, in the radar's own coordinate frame:
///   x  = lateral offset in mm  (negative = left, positive = right)
///   y  = forward distance in mm (always ≥ 0, straight out from the sensor)
struct LD2450Target: Identifiable {
    let id: Int          // slot 1…3
    let x: Double        // mm
    let y: Double        // mm
    /// Straight-line distance from the sensor, in metres.
    var distanceMeters: Double { (x * x + y * y).squareRoot() / 1000.0 }
}

struct LD2450Reading {
    let targetCount: Int
    let movingCount: Int
    let targets: [LD2450Target]   // only the currently-active slots
    let personPresent: Bool
    let timestamp: Date
}

// File-scoped decodables (C6RadarClient's are private to that type).
private struct ESPValue: Decodable { let value: Double? }
private struct ESPBoolValue: Decodable { let value: Bool? }

/// Polls the ESPHome HTTP/JSON endpoints on the LD2450 node directly, exactly
/// like `C6RadarClient` does for the C6 — no server/bridge required. Surfaces
/// a live person count plus up to three (x, y) target positions.
///   /sensor/target_count            {"value": 1}
///   /sensor/moving_target_count     {"value": 0}
///   /sensor/target_N_x|_y           {"value": -352}  | value:null when slot empty
///   /binary_sensor/person_present   {"value": true}
@MainActor
final class LD2450Client: ObservableObject {

    @Published var reading: LD2450Reading?
    @Published var isReachable: Bool = false

    private var host: String = ""
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession

    // Snappier than the C6 (1.5s) because X/Y tracking should feel live.
    private let pollInterval: TimeInterval = 0.7
    private var consecutiveFailures: Int = 0

    // LD2450 rated maximum range is 6 m. Targets reported beyond that are not
    // physically valid — with the antenna disconnected the radar hallucinates a
    // persistent "still" ghost out at ~7 m, which inflated the count to 2. Gate
    // on the rated range so only real, in-range targets are counted. Also stays
    // correct once the antenna is attached (real targets are always ≤ 6 m).
    private let maxRangeMeters: Double = 6.0
    private let reachableMaxFailures: Int = 3

    // Count stabilisation (mirrors the server bridge). Two tracks closer than
    // `desplitMeters` are one person the radar split in the near field; a raised
    // count must persist `countPersist` polls before we report it (kills 1→2→1
    // flicker), while drops apply immediately so walk-out stays fast.
    private let desplitMeters: Double = 0.7
    private let countPersist: Int = 3
    private var lastStableCount: Int = 0
    private var countCandidate: Int = 0
    private var countStreak: Int = 0

    /// Collapse targets closer than `desplitMeters` into one cluster.
    private func desplitCount(_ ts: [LD2450Target]) -> Int {
        var used = Array(repeating: false, count: ts.count)
        var clusters = 0
        for i in ts.indices where !used[i] {
            clusters += 1
            for j in (i + 1)..<ts.count where !used[j] {
                let dx = ts[i].x - ts[j].x, dy = ts[i].y - ts[j].y
                if (dx * dx + dy * dy).squareRoot() / 1000.0 < desplitMeters { used[j] = true }
            }
        }
        return clusters
    }

    /// Persistence + hysteresis gate over the de-split count.
    private func stabilizedCount(_ raw: Int) -> Int {
        if raw <= lastStableCount {
            lastStableCount = raw; countCandidate = raw; countStreak = 0
        } else {
            if raw == countCandidate { countStreak += 1 } else { countCandidate = raw; countStreak = 1 }
            if countStreak >= countPersist { lastStableCount = raw }
        }
        return lastStableCount
    }

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)
    }

    func start(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pollTask != nil && trimmed == self.host { return }
        stop()
        self.host = trimmed
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isReachable = false
        reading = nil
        consecutiveFailures = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty else { return }
        async let count   = fetchNumeric("/sensor/target_count")
        async let moving  = fetchNumeric("/sensor/moving_target_count")
        async let present = fetchBool("/binary_sensor/person_present")
        async let t1x = fetchNumeric("/sensor/target_1_x")
        async let t1y = fetchNumeric("/sensor/target_1_y")
        async let t2x = fetchNumeric("/sensor/target_2_x")
        async let t2y = fetchNumeric("/sensor/target_2_y")
        async let t3x = fetchNumeric("/sensor/target_3_x")
        async let t3y = fetchNumeric("/sensor/target_3_y")

        let countR = await count, movingR = await moving, presentR = await present
        let xs = [await t1x, await t2x, await t3x]
        let ys = [await t1y, await t2y, await t3y]

        // If the whole node is unreachable, drop the card after a few misses.
        if countR == nil && presentR == nil && xs.allSatisfy({ $0 == nil }) {
            consecutiveFailures += 1
            if consecutiveFailures >= reachableMaxFailures {
                isReachable = false
                reading = nil
            }
            return
        }

        var targets: [LD2450Target] = []
        for i in 0..<3 {
            // A slot is active only when it reports a real coordinate. Empty
            // slots come back as value:null, and a parked (0,0) means no target.
            // Reject anything beyond the rated range — that's ghost, not person.
            if let x = xs[i], let y = ys[i], !(x == 0 && y == 0) {
                let t = LD2450Target(id: i + 1, x: x, y: y)
                if t.distanceMeters <= maxRangeMeters {
                    targets.append(t)
                }
            }
        }

        consecutiveFailures = 0
        isReachable = true
        // De-split near-field body-splits, then require a raised count to persist.
        let stableCount = stabilizedCount(desplitCount(targets))
        reading = LD2450Reading(
            // Count from validated, in-range, de-split + persisted targets — NOT
            // the raw target_count register (out-of-range ghosts, near-field splits).
            targetCount: stableCount,
            movingCount: movingR.map { Int($0) } ?? 0,
            targets: targets,
            personPresent: presentR ?? !targets.isEmpty,
            timestamp: Date()
        )
    }

    // Returns nil on HTTP/parse failure OR on ESPHome `value:null`.
    private func fetchNumeric(_ path: String) async -> Double? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ESPValue.self, from: data).value
        } catch { return nil }
    }

    private func fetchBool(_ path: String) async -> Bool? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ESPBoolValue.self, from: data).value
        } catch { return nil }
    }
}

// MARK: - LD2410C (24 GHz presence + distance radar)

struct LD2410Reading {
    let personPresent: Bool
    let movingPresent: Bool
    let stillPresent: Bool
    let movingDistanceCm: Double?
    let stillDistanceCm: Double?
    let movingEnergy: Double?     // 0–100 %
    let stillEnergy: Double?      // 0–100 %
    let detectionDistanceCm: Double?
    let timestamp: Date

    /// "Moving" / "Still" / "Clear" summary of the current motion state.
    var motionLabel: String {
        if movingPresent { return "Moving" }
        if stillPresent  { return "Still" }
        return "Clear"
    }

    /// Best single distance estimate, in metres (nil when no target).
    var distanceMeters: Double? {
        let cm: Double?
        if movingPresent      { cm = movingDistanceCm }
        else if stillPresent  { cm = stillDistanceCm }
        else                  { cm = detectionDistanceCm }
        guard let cm, cm > 0 else { return nil }
        return cm / 100.0
    }
}

/// Direct ESPHome poller for the LD2410C presence node — same approach as the
/// LD2450/C6 clients. Reports presence, moving/still state, distance, energy.
@MainActor
final class LD2410Client: ObservableObject {

    @Published var reading: LD2410Reading?
    @Published var isReachable: Bool = false

    private var host: String = ""
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession
    private let pollInterval: TimeInterval = 1.0
    private var consecutiveFailures: Int = 0
    private let reachableMaxFailures: Int = 3

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)
    }

    func start(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pollTask != nil && trimmed == self.host { return }
        stop()
        self.host = trimmed
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isReachable = false
        reading = nil
        consecutiveFailures = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty else { return }
        async let present = fetchBool("/binary_sensor/person_present")
        async let moving  = fetchBool("/binary_sensor/moving_target_present")
        async let still   = fetchBool("/binary_sensor/still_target_present")
        async let md = fetchNumeric("/sensor/moving_target_distance")
        async let sd = fetchNumeric("/sensor/still_target_distance")
        async let mE = fetchNumeric("/sensor/moving_target_energy")
        async let sE = fetchNumeric("/sensor/still_target_energy")
        async let dd = fetchNumeric("/sensor/detection_distance")

        let presentR = await present, movingR = await moving, stillR = await still
        let mdR = await md, sdR = await sd, mER = await mE, sER = await sE, ddR = await dd

        if presentR == nil && mdR == nil && sdR == nil && ddR == nil {
            consecutiveFailures += 1
            if consecutiveFailures >= reachableMaxFailures {
                isReachable = false
                reading = nil
            }
            return
        }

        consecutiveFailures = 0
        isReachable = true
        reading = LD2410Reading(
            personPresent: presentR ?? false,
            movingPresent: movingR ?? false,
            stillPresent: stillR ?? false,
            movingDistanceCm: mdR,
            stillDistanceCm: sdR,
            movingEnergy: mER,
            stillEnergy: sER,
            detectionDistanceCm: ddR,
            timestamp: Date()
        )
    }

    private func fetchNumeric(_ path: String) async -> Double? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ESPValue.self, from: data).value
        } catch { return nil }
    }

    private func fetchBool(_ path: String) async -> Bool? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ESPBoolValue.self, from: data).value
        } catch { return nil }
    }
}

// MARK: - INMP441 (I²S audio level)

struct MicReading {
    let leqDb: Double?     // A/eq sound level, dBFS (negative)
    let peakDb: Double?    // peak level, dBFS
    let timestamp: Date
}

/// Direct ESPHome poller for the INMP441 audio node — reads the on-device
/// sound-level-meter (Leq + Peak). Same pattern as the radar clients.
@MainActor
final class MicClient: ObservableObject {

    @Published var reading: MicReading?
    @Published var isReachable: Bool = false

    private var host: String = ""
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession
    private let pollInterval: TimeInterval = 1.0
    private var consecutiveFailures: Int = 0
    private let reachableMaxFailures: Int = 3

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)
    }

    func start(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pollTask != nil && trimmed == self.host { return }
        stop()
        self.host = trimmed
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isReachable = false
        reading = nil
        consecutiveFailures = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty else { return }
        // Object-ids: "Audio Level (Leq)" -> audio_level__leq_ ; "Audio Peak" -> audio_peak
        async let leq  = fetchNumeric("/sensor/audio_level__leq_")
        async let peak = fetchNumeric("/sensor/audio_peak")
        let l = await leq, p = await peak

        if l == nil && p == nil {
            consecutiveFailures += 1
            if consecutiveFailures >= reachableMaxFailures {
                isReachable = false
                reading = nil
            }
            return
        }
        consecutiveFailures = 0
        isReachable = true
        reading = MicReading(leqDb: l, peakDb: p, timestamp: Date())
    }

    private func fetchNumeric(_ path: String) async -> Double? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            // -inf/inf come back as non-finite; treat as no reading.
            if let v = try JSONDecoder().decode(ESPValue.self, from: data).value, v.isFinite {
                return v
            }
            return nil
        } catch { return nil }
    }
}
