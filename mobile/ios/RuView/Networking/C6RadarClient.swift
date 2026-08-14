import Foundation

// MARK: - C6RadarReading

struct C6RadarReading {
    let heartRateBpm: Double?      // nil when radar reports no target
    let breathingRateBpm: Double?  // nil when radar reports no target
    let targetDistanceCm: Double?  // nil when no target
    let personPresent: Bool
    let wifiRssiDbm: Double?
    let timestamp: Date

    // Clutter gate (see C6RadarClient.evaluateTrust). The MR60BHA2 happily
    // reports a rock-steady "heartbeat" off a static object in its near field
    // (a chair, a wall reflection) — that's the phantom that got the C6 pulled.
    // `vitalsTrusted` is true only when the reading looks like a living subject;
    // `rejectReason` explains why it doesn't, for the UI.
    let vitalsTrusted: Bool
    let rejectReason: String?

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

    private let pollInterval: TimeInterval = 0.5
    private var consecutiveFailures: Int = 0
    private let reachableMaxFailures: Int = 2

    // MARK: - Clutter / trust gate
    //
    // The MR60BHA2 is a bedside/armchair vitals radar: it reads chest
    // micro-motion reliably at ~0.4–1.5 m facing the torso, and NOTHING past
    // that. Point it at a room and it locks onto static clutter (furniture, a
    // wall echo) and emits a dead-constant "heartbeat" — the phantom. We reject
    // that in software so the app never shows a fabricated vital.
    private struct VitalSample {
        let hr: Double?
        let br: Double?
        let dist: Double?
        let present: Bool
        let t: Date
    }
    private var window: [VitalSample] = []
    private let windowSpanSec: TimeInterval = 12   // rolling analysis window
    private let minSamples = 6                      // ~9 s at 1.5 s cadence
    // MR60BHA2 trustworthy near field (~0.2 m min per Seeed spec, up to ~2 m).
    private let distMinCm = 18.0
    private let distMaxCm = 200.0
    // Physiological bands — anything outside is not a resting human.
    private let hrBand = 40.0 ... 130.0
    private let brBand = 6.0 ... 34.0
    // A living subject's estimate always jitters breath-to-breath; static
    // clutter pins a near-constant value. Require variation in HR *or* BR.
    private let minHrStd = 0.4
    private let minBrStd = 0.3
    // A walking person (distance swinging wildly) isn't a resting vitals subject.
    private let maxDistStd = 50.0
    // Once trusted, stay trusted briefly so a momentary lock dropout (the
    // MR60BHA2 routinely drops BR for a beat or two) doesn't flicker the UI.
    private let trustHoldSec: TimeInterval = 3.0
    private var trustedUntil: Date?

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
        window.removeAll()
        trustedUntil = nil
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

        let presentFlag = presentRes.bool ?? false
        let (trusted, reason) = evaluateTrust(
            hr: hrRes.value, br: brRes.value, dist: distRes.value, present: presentFlag
        )
        reading = C6RadarReading(
            heartRateBpm:      hrRes.value,
            breathingRateBpm:  brRes.value,
            targetDistanceCm:  distRes.value,
            personPresent:     presentFlag,
            wifiRssiDbm:       rssiRes.value,
            timestamp:         Date(),
            vitalsTrusted:     trusted,
            rejectReason:      reason
        )
    }

    /// Decide whether the current reading is a real living subject or clutter.
    /// Appends to the rolling window, prunes it, then applies the gate.
    private func evaluateTrust(hr: Double?, br: Double?, dist: Double?, present: Bool) -> (Bool, String?) {
        let now = Date()
        window.append(VitalSample(hr: hr, br: br, dist: dist, present: present, t: now))
        window.removeAll { now.timeIntervalSince($0.t) > windowSpanSec }

        let (trusted, reason) = rawTrust(hr: hr, br: br, dist: dist, present: present, now: now)
        if trusted {
            trustedUntil = now.addingTimeInterval(trustHoldSec)
            return (true, nil)
        }
        // Hold a recent trust through a momentary dropout so the UI doesn't flicker.
        if let until = trustedUntil, now < until, present {
            return (true, nil)
        }
        trustedUntil = nil
        return (false, reason)
    }

    /// The per-reading gate, before the trust-hold smoothing. HR is the anchor
    /// (a valid, jittering heartbeat = a living subject); BR is advisory — the
    /// MR60BHA2 routinely loses the breathing lock for a beat without the
    /// subject leaving.
    private func rawTrust(hr: Double?, br: Double?, dist: Double?, present: Bool, now: Date) -> (Bool, String?) {
        guard present else { return (false, "No target in the beam") }
        guard let hr, let dist else { return (false, "No vitals lock") }
        guard dist >= distMinCm, dist <= distMaxCm else {
            return (false, "Out of range — sit within 0.2–1.5 m, facing the sensor")
        }
        guard hrBand.contains(hr) else {
            return (false, "Heart rate outside physiological range")
        }
        guard window.count >= minSamples else { return (false, "Warming up…") }

        let hrs = window.compactMap { $0.hr }.filter { $0 > 0 }
        let brs = window.compactMap { $0.br }.filter { $0 > 0 }
        let dists = window.compactMap { $0.dist }.filter { $0 > 0 }

        if Self.std(dists) > maxDistStd {
            return (false, "Subject moving — not a resting reading")
        }
        // The clutter signature: a value frozen to a near-constant. A real
        // subject varies in HR or BR; static clutter varies in neither.
        if Self.std(hrs) < minHrStd, Self.std(brs) < minBrStd {
            return (false, "Static clutter — no living subject")
        }
        return (true, nil)
    }

    private static func std(_ xs: [Double]) -> Double {
        guard xs.count >= 2 else { return .infinity }  // too few samples ⇒ don't trust "flat"
        let mean = xs.reduce(0, +) / Double(xs.count)
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return variance.squareRoot()
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
    let speed: Double?   // cm/s, signed (− = approaching); nil when unreported
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
    private let pollInterval: TimeInterval = 0.5
    private var consecutiveFailures: Int = 0

    // LD2450 rated maximum range is 6 m. Targets reported beyond that are not
    // physically valid — with the antenna disconnected the radar hallucinates a
    // persistent "still" ghost out at ~7 m, which inflated the count to 2. Gate
    // on the rated range so only real, in-range targets are counted. Also stays
    // correct once the antenna is attached (real targets are always ≤ 6 m).
    private let maxRangeMeters: Double = 6.0
    private let reachableMaxFailures: Int = 3

    // Ghost rejection by physics: a static reflector (wall/corner/metal) that
    // the LD2450 hallucinates as a target reports a nonsensical speed — we've
    // seen ±1190 cm/s (11.9 m/s) off an empty hall. No human moves that fast
    // indoors (a brisk walk is ~1.4 m/s, a run ~4 m/s), so any target whose
    // reported speed exceeds this cap is a reflection, not a person. A real
    // still person reads ~0 cm/s and passes untouched.
    private let maxHumanSpeedCmS: Double = 350.0

    // Count stabilisation. Two tracks closer than `desplitMeters` are one person
    // the radar split in the near field → merged. Then a HOLD: mmWave is
    // motion-based and intermittently loses a motionless person, so once we see
    // ≥1 we hold the count through dropouts for `countHoldSec` before clearing.
    // Raise is immediate (responsive); a real walk-out clears after the hold.
    private let desplitMeters: Double = 0.7
    private let countHoldSec: TimeInterval = 5.0
    private var heldCount: Int = 0
    private var heldCountAt: Date = .distantPast

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

    /// Hold the de-split count through the LD2450's still-person dropouts:
    /// raise immediately, but keep a detected count for `countHoldSec` after the
    /// raw reading drops to 0 (a motionless person the radar momentarily lost).
    private func stabilizedCount(_ desplit: Int) -> Int {
        let now = Date()
        if desplit >= 1 {
            heldCount = desplit
            heldCountAt = now
            return desplit
        }
        if now.timeIntervalSince(heldCountAt) < countHoldSec {
            return heldCount           // dropout — hold last count, person likely still there
        }
        heldCount = 0
        return 0
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
        async let t1s = fetchNumeric("/sensor/target_1_speed")
        async let t2s = fetchNumeric("/sensor/target_2_speed")
        async let t3s = fetchNumeric("/sensor/target_3_speed")

        let countR = await count, movingR = await moving, presentR = await present
        let xs = [await t1x, await t2x, await t3x]
        let ys = [await t1y, await t2y, await t3y]
        let speeds = [await t1s, await t2s, await t3s]

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
            if let x = xs[i], let y = ys[i], !(x == 0 && y == 0) {
                let t = LD2450Target(id: i + 1, x: x, y: y, speed: speeds[i])
                // Reject beyond the rated range — that's ghost, not person.
                guard t.distanceMeters <= maxRangeMeters else { continue }
                // Reject nonphysical speed — a static reflector the radar
                // hallucinates as a target (empty-hall ghost at ±11.9 m/s).
                if let v = speeds[i], abs(v) > maxHumanSpeedCmS { continue }
                targets.append(t)
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

    // Clutter floors, tuned against a live empty room. The LD2410C's
    // has_moving_target / has_still_target BINARY flags are unreliable — in an
    // empty hall the moving flag fires ~half the time at 0% energy off a wall
    // reflection. The ENERGY is the honest signal: that reflector never cleared
    // 16% moving / 13% still, while a real body runs 50–100%. So we gate on
    // energy, not the flags.
    static let movingBodyEnergyFloor: Double = 35.0
    static let stillBodyEnergyFloor: Double = 20.0

    /// Presence we trust for occupancy: a moving OR still return whose energy
    /// clears the clutter floor. This is what keeps an empty room from reading
    /// "occupied" off a static reflection.
    var isTrustworthyPresence: Bool {
        if let e = movingEnergy, e >= LD2410Reading.movingBodyEnergyFloor { return true }
        if let e = stillEnergy,  e >= LD2410Reading.stillBodyEnergyFloor  { return true }
        return false
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
    private let pollInterval: TimeInterval = 0.5
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
    private let pollInterval: TimeInterval = 0.5
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

// MARK: - AudioClient (Pi voice-intelligence REST, :3025)
//
// Thin client for the Orange Pi's ruview-audiod. The Pi does ALL the audio
// work (ESP32 mic → UDP → YAMNet → radar fusion); the app only renders the
// result. Endpoint: GET http://<pi>:3025/api/v1/audio

struct AudioEvent: Identifiable {
    let id = UUID()
    let label: String
    let score: Double
}

struct AudioReading {
    let levelDb: Double?
    let active: Bool
    let events: [AudioEvent]
    let fused: String        // "conversation" | "tv_or_media" | "distress_present" | …
    let radarPresent: Bool?
    let stream: String       // "up" | "down"
    let timestamp: Date
}

private struct AudioEventDTO: Decodable { let label: String; let score: Double }
private struct AudioDTO: Decodable {
    let level_db: Double?
    let active: Bool?
    let events: [AudioEventDTO]?
    let fused: String?
    let radar_present: Bool?
    let stream: String?
}

@MainActor
final class AudioClient: ObservableObject {
    @Published var reading: AudioReading?
    @Published var isReachable: Bool = false

    private var host: String = ""            // Pi host (sensing-server host)
    private let port: Int = 3025
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession
    private let pollInterval: TimeInterval = 0.5
    private var consecutiveFailures = 0
    private let maxFailures = 3

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
        pollTask?.cancel(); pollTask = nil
        isReachable = false; reading = nil; consecutiveFailures = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(port)/api/v1/audio") else { return }
        do {
            let (data, resp) = try await urlSession.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let dto = try? JSONDecoder().decode(AudioDTO.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            consecutiveFailures = 0
            isReachable = true
            reading = AudioReading(
                levelDb: dto.level_db,
                active: dto.active ?? false,
                events: (dto.events ?? []).map { AudioEvent(label: $0.label, score: $0.score) },
                fused: dto.fused ?? "idle",
                radarPresent: dto.radar_present,
                stream: dto.stream ?? "down",
                timestamp: Date())
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= maxFailures { isReachable = false; reading = nil }
        }
    }
}

// MARK: - BLEHeartClient (Pi BLE heart-rate REST, :3027)
//
// Thin client for the Orange Pi's ruview-hrd bridge. A BLE HR strap/ring
// (Bluetooth-SIG Heart Rate Service 0x180D) → ruview-ble-hr-decoder → MQTT →
// ruview-hrd → this. The Pi owns the BLE + decode; the app just renders.
// Endpoint: GET http://<pi>:3027/api/v1/hr

struct BLEHeartReading {
    let bpm: Int?
    let hrvMs: Double?          // RMSSD, ms — heart-rate variability
    let sensorContact: String   // "detected" | "not_detected" | "not_supported"
    let device: String?
    let ageSec: Double?
    let stream: String          // "up" (fresh) | "down" (stale/no device)
    let timestamp: Date

    /// A live, usable heartbeat right now.
    var isLive: Bool { stream == "up" && (bpm ?? 0) > 0 }
    /// The strap reports it's actually on the skin (or doesn't expose contact).
    var contactOk: Bool { sensorContact != "not_detected" }
}

private struct HRDTO: Decodable {
    let bpm: Int?
    let hrv_ms: Double?
    let sensor_contact: String?
    let device: String?
    let age_sec: Double?
    let stream: String?
}

@MainActor
final class BLEHeartClient: ObservableObject {
    @Published var reading: BLEHeartReading?
    @Published var isReachable: Bool = false

    private var host: String = ""
    private let port: Int = 3027
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession
    private let pollInterval: TimeInterval = 1.0
    private var consecutiveFailures = 0
    private let maxFailures = 3

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
        pollTask?.cancel(); pollTask = nil
        isReachable = false; reading = nil; consecutiveFailures = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(port)/api/v1/hr") else { return }
        do {
            let (data, resp) = try await urlSession.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let dto = try? JSONDecoder().decode(HRDTO.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            consecutiveFailures = 0
            isReachable = true
            reading = BLEHeartReading(
                bpm: dto.bpm,
                hrvMs: dto.hrv_ms,
                sensorContact: dto.sensor_contact ?? "not_supported",
                device: dto.device,
                ageSec: dto.age_sec,
                stream: dto.stream ?? "down",
                timestamp: Date())
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= maxFailures { isReachable = false; reading = nil }
        }
    }
}

// MARK: - CountClient (Pi CSI person-count model REST, :3028)
//
// Thin client for the Orange Pi's ruview-countd, which supervises the
// cog-person-count Candle CNN (CSI → person count). The Pi owns inference;
// the app renders the model's count. Endpoint: GET http://<pi>:3028/api/v1/count
// Idle (stream "down") until CSI is flowing.

struct ModelCountReading {
    let count: Int?
    let confidence: Double?      // model confidence (0–1); note: uncalibrated
    let p95Low: Int?
    let p95High: Int?
    let stream: String           // "up" (fresh) | "down" (no CSI / stale)
    let timestamp: Date

    var isLive: Bool { stream == "up" && count != nil }
}

private struct CountDTO: Decodable {
    let count: Int?
    let confidence: Double?
    let p95_low: Int?
    let p95_high: Int?
    let stream: String?
    // `timestamp` is a float epoch from the cog — intentionally not decoded;
    // the client stamps its own receipt time.
}

@MainActor
final class CountClient: ObservableObject {
    @Published var reading: ModelCountReading?
    @Published var isReachable: Bool = false

    private var host: String = ""
    private let port: Int = 3028
    private var pollTask: Task<Void, Never>?
    private let urlSession: URLSession
    private let pollInterval: TimeInterval = 0.75
    private var consecutiveFailures = 0
    private let maxFailures = 3

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
        pollTask?.cancel(); pollTask = nil
        isReachable = false; reading = nil; consecutiveFailures = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(port)/api/v1/count") else { return }
        do {
            let (data, resp) = try await urlSession.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let dto = try? JSONDecoder().decode(CountDTO.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            consecutiveFailures = 0
            isReachable = true
            reading = ModelCountReading(
                count: dto.count,
                confidence: dto.confidence,
                p95Low: dto.p95_low,
                p95High: dto.p95_high,
                stream: dto.stream ?? "down",
                timestamp: Date())
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= maxFailures { isReachable = false; reading = nil }
        }
    }
}
