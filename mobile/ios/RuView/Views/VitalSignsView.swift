import SwiftUI

// MARK: - VitalSignsView

struct VitalSignsView: View {
    @ObservedObject var viewModel: SensingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let csiVitals = viewModel.snapshot?.vitalSigns
                let csiUsable = csiVitals.map(csiVitalsUsable) ?? false
                let hasAnyVitals = viewModel.bleHrReachable || viewModel.radarReachable || csiUsable

                // Only show "measuring" when a vitals source is actually connected.
                if viewModel.isMeasuring && (viewModel.radarReachable || viewModel.bleHrReachable) {
                    measuringBanner
                }

                // BLE strap = the accurate, contact-based heart-rate source.
                if viewModel.bleHrReachable {
                    SectionHeader(title: "Heart Rate — BLE strap")
                    bleHeartCard
                }

                if let vitals = csiVitals, csiUsable {
                    SectionHeader(title: "Vital Signs", trailing: liveTimestamp)
                    heartRateCard(vitals: vitals)
                    breathingCard(vitals: vitals)
                    SectionHeader(title: "Signal")
                    signalQualityCard(vitals: vitals)
                }

                if viewModel.radarReachable {
                    SectionHeader(title: "60 GHz Radar (C6)")
                    radarCard
                }

                if hasAnyVitals {
                    disclaimerFooter
                } else {
                    noDataCard
                }
            }
            .padding(16)
        }
        .background(Color.steelPale.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Vital Signs")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await viewModel.refreshNodes()
            await viewModel.refreshAdaptiveStatus()
            await viewModel.refreshCalibrationStatus()
        }
    }

    private var liveTimestamp: String {
        viewModel.isLiveDataFlowing ? "Updated just now" : "Waiting for data"
    }

    /// The WiFi-CSI vitals section is worth showing only when at least one
    /// metric actually has data. When both are `.unavailable` the cards would
    /// render a false-alarm "Sensor failure — no recent data" even though the
    /// C6 mmWave card below is live — so hide the whole section in that case.
    private func csiVitalsUsable(_ vitals: VitalSigns) -> Bool {
        switch (viewModel.heartRateDisplay(vitals: vitals),
                viewModel.breathingDisplay(vitals: vitals)) {
        case (.unavailable, .unavailable): return false
        default: return true
        }
    }

    private var disclaimerFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.caption2)
            Text("Non-medical estimate — WiFi-CSI sensing for monitoring only.")
                .font(.caption2)
                .multilineTextAlignment(.leading)
        }
        .foregroundColor(.healthSub)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Measuring banner

    private var measuringBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.85)
            VStack(alignment: .leading, spacing: 2) {
                Text("Measuring…")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text("Vital signs take 30 seconds to stabilize after connection.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(14)
        .background(SteelGradient.horizontal)
        .cornerRadius(14)
        .shadow(color: Color.steel.opacity(0.30), radius: 8, x: 0, y: 4)
    }

    // MARK: - Vital cards

    private func heartRateCard(vitals: VitalSigns) -> some View {
        let display = viewModel.heartRateDisplay(vitals: vitals)
        let status: MetricStatus = {
            switch display {
            case .live(let v), .approximate(let v):
                return .forHeartRate(Double(v))
            case .held, .unavailable:
                return .unknown
            }
        }()
        return HealthVitalCard(
            icon: "heart.fill", iconColor: .heartRed,
            title: "Heart Rate",
            display: display,
            unit: "BPM",
            confidence: vitals.heartbeatConfidence,
            accentColor: .heartRed,
            history: viewModel.heartRateHistory,
            referenceRange: "Typical resting: 60 – 100 BPM",
            status: status,
            trend: viewModel.heartRateTrend()
        )
    }

    private func breathingCard(vitals: VitalSigns) -> some View {
        let display = viewModel.breathingDisplay(vitals: vitals)
        let status: MetricStatus = {
            switch display {
            case .live(let v), .approximate(let v):
                return .forBreathingRate(Double(v))
            case .held, .unavailable:
                return .unknown
            }
        }()
        return HealthVitalCard(
            icon: "lungs.fill", iconColor: .lungTeal,
            title: "Breathing Rate",
            display: display,
            unit: "BPM",
            confidence: vitals.breathingConfidence,
            accentColor: .lungTeal,
            history: viewModel.breathingHistory,
            referenceRange: "Typical resting: 12 – 20 BPM",
            status: status,
            trend: viewModel.breathingTrend()
        )
    }

    // MARK: - BLE heart-rate strap (0x180D via Pi ruview-hrd)

    private var bleHeartCard: some View {
        let r = viewModel.bleHeartReading
        let live = r?.isLive ?? false
        let bpm: Double? = live ? r?.bpm.map(Double.init) ?? nil : nil
        let hrv: Double? = live ? r?.hrvMs : nil

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.heartRed)
                Text("BLE heart-rate strap")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.healthText)
                Spacer()
                bleContactChip(live: live, contact: r?.sensorContact ?? "not_supported")
            }

            HStack(spacing: 14) {
                radarMetric(icon: "heart.fill", color: .heartRed,
                            label: "Heart", value: bpmText(bpm), unit: "BPM")
                radarMetric(icon: "waveform.path.ecg", color: .steel,
                            label: "HRV", value: hrvText(hrv), unit: "ms")
            }

            if live, r?.sensorContact == "not_detected" {
                Text("Strap not on skin — reading paused")
                    .font(.caption).foregroundColor(.orange)
            }
            if let r, let dev = r.device {
                Text("\(dev) · updated \(ageString(r.timestamp)) ago")
                    .font(.caption2).foregroundColor(.healthSub)
            }
        }
        .ruCard()
    }

    private func bleContactChip(live: Bool, contact: String) -> some View {
        let (label, color): (String, Color) =
            !live ? ("No strap", .healthSub)
            : contact == "not_detected" ? ("Off skin", .orange)
            : ("Live", .green)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.10)).cornerRadius(6)
    }

    private func hrvText(_ v: Double?) -> String {
        guard let v, v > 0 else { return "–" }
        return "\(Int(v.rounded()))"
    }

    // MARK: - 60GHz Radar (ESP32-C6 + MR60BHA2, polled directly)

    private var radarCard: some View {
        let r = viewModel.radarReading
        let present = r?.personPresent ?? false
        let trusted = r?.vitalsTrusted ?? false
        let dist = r?.targetDistanceCm
        // Only show the pulse/breath numbers when the reading passed the clutter
        // gate — otherwise the MR60BHA2's phantom would read as a real vital.
        // Clamp to sane bands too, so a held-trust moment where BR briefly loses
        // lock shows "–" rather than a nonsense 2–3 bpm.
        let hrRaw = r?.heartRateBpm ?? 0
        let brRaw = r?.breathingRateBpm ?? 0
        let hr: Double? = (trusted && hrRaw >= 40 && hrRaw <= 130) ? hrRaw : nil
        let br: Double? = (trusted && brRaw >= 6 && brRaw <= 34) ? brRaw : nil

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.steel)
                Text("60 GHz mmWave radar")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.healthText)
                Spacer()
                vitalsStatusChip(trusted: trusted, present: present)
            }

            HStack(spacing: 14) {
                radarMetric(
                    icon: "heart.fill", color: .heartRed,
                    label: "Heart", value: bpmText(hr), unit: "BPM"
                )
                radarMetric(
                    icon: "lungs.fill", color: .lungTeal,
                    label: "Breath", value: bpmText(br), unit: "BPM"
                )
                radarMetric(
                    icon: "ruler", color: .steel,
                    label: "Range", value: distanceText(dist), unit: "cm"
                )
            }

            // When the gate rejected the reading, say why (placement guidance).
            if !trusted, let reason = r?.rejectReason {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(reason)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
                .cornerRadius(8)
            }

            if let r {
                Text("Updated \(ageString(r.timestamp)) ago")
                    .font(.caption2)
                    .foregroundColor(.healthSub)
            }
        }
        .ruCard()
    }

    /// Status chip: green "Live vitals" only when the clutter gate passed;
    /// amber "Checking…" when a target is present but not yet trusted; grey when
    /// no target at all.
    private func vitalsStatusChip(trusted: Bool, present: Bool) -> some View {
        let (label, color): (String, Color) =
            trusted ? ("Live vitals", .green)
            : present ? ("Checking…", .orange)
            : ("No target", .healthSub)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.10))
        .cornerRadius(6)
    }

    private func presenceChip(present: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(present ? Color.green : Color.healthSub.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(present ? "Person detected" : "No target")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(present ? .green : .healthSub)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((present ? Color.green : Color.healthSub).opacity(0.10))
        .cornerRadius(6)
    }

    private func radarMetric(icon: String, color: Color, label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(.healthSub)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.healthText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if value != "–" {
                    Text(unit)
                        .font(.caption2).fontWeight(.medium)
                        .foregroundColor(.healthSub)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.steelPale.opacity(0.6))
        .cornerRadius(10)
    }

    private func bpmText(_ v: Double?) -> String {
        guard let v, v > 0 else { return "–" }
        return "\(Int(v.rounded()))"
    }

    private func distanceText(_ v: Double?) -> String {
        guard let v, v > 0 else { return "–" }
        return "\(Int(v.rounded()))"
    }

    private func ageString(_ t: Date) -> String {
        let secs = Int(Date().timeIntervalSince(t))
        if secs <= 1 { return "just now" }
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m"
    }

    // MARK: - Signal quality

    private func signalQualityCard(vitals: VitalSigns) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Signal Quality", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundColor(.healthText)

            HStack(spacing: 20) {
                RingGauge(value: vitals.signalQuality, color: signalQualityColor(vitals.signalQuality))
                    .frame(width: 70, height: 70)

                VStack(alignment: .leading, spacing: 6) {
                    Text(signalQualityLabel(vitals.signalQuality))
                        .font(.title3).fontWeight(.semibold)
                        .foregroundColor(signalQualityColor(vitals.signalQuality))
                    Text("\(String(format: "%.0f%%", vitals.signalQuality * 100)) signal strength")
                        .font(.subheadline).foregroundColor(.healthSub)

                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach([0, 1, 2, 3], id: \.self) { i in
                            let filled = vitals.signalQuality > Double(i) * 0.25
                            RoundedRectangle(cornerRadius: 2)
                                .fill(filled ? signalQualityColor(vitals.signalQuality) : Color.steelLight.opacity(0.35))
                                .frame(width: 7, height: CGFloat(8 + i * 5))
                        }
                    }
                }
                Spacer()
            }
        }
        .ruCard()
    }

    // MARK: - No data

    private var noDataCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.slash")
                .font(.system(size: 48))
                .foregroundColor(.steelLight)
            Text("No vitals sensor")
                .font(.headline).foregroundColor(.healthSub)
            Text("Heart-rate / breathing needs the 60 GHz radar (C6), which is offline. Presence, count, motion and sound are all live on the other tabs.")
                .font(.callout).foregroundColor(.healthSub).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .ruCard()
    }

    // MARK: - Helpers

    private func signalQualityLabel(_ q: Double) -> String {
        if q >= 0.8 { return "Excellent" }
        if q >= 0.6 { return "Good" }
        if q >= 0.4 { return "Fair" }
        if q >= 0.2 { return "Poor" }
        return "Very poor"
    }

    private func signalQualityColor(_ q: Double) -> Color {
        if q >= 0.6 { return .steel }
        if q >= 0.4 { return .orange }
        return .red
    }
}

// MARK: - HealthVitalCard

private struct HealthVitalCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let display: SensingViewModel.VitalDisplay
    let unit: String
    let confidence: Double
    let accentColor: Color
    let history: [Double]
    let referenceRange: String
    let status: MetricStatus
    let trend: SensingViewModel.VitalTrend

    @State private var pulsing = false

    private var value: String { display.text }
    private var isHeld: Bool { display.isHeld }
    private var isUnavailable: Bool {
        if case .unavailable = display { return true } else { return false }
    }
    private var isLow: Bool { confidence < 0.3 && !isHeld }
    private var isMed: Bool { confidence >= 0.3 && confidence < 0.6 && !isHeld }
    private var showStatus: Bool { status != .unknown && !isHeld && !isUnavailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(pulsing && !isLow ? 0.14 : 0.10))
                        .frame(width: 52, height: 52)
                        .scaleEffect(pulsing && !isLow ? 1.04 : 1.0)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulsing)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(iconColor)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(.healthSub)
                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value)
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundColor(isLow || isUnavailable ? .healthSub : .healthText)
                            .opacity(isHeld ? 0.65 : 1.0)
                            .contentTransition(.numericText())
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        if value != "–" {
                            Text(unit)
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundColor(.healthSub)
                                .tracking(0.5)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }

                    Text(referenceRange)
                        .font(.caption2)
                        .foregroundColor(.healthSub)

                    if isHeld, let age = display.heldAge {
                        heldBadge(age: age)
                    } else if isUnavailable {
                        Label("Sensor failure — no recent data",
                              systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption).foregroundColor(.orange)
                    } else if showStatus {
                        MetricStatusBadge(status: status, compact: true)
                            .padding(.top, 2)
                    } else if isLow {
                        Label("Low signal — measuring", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption).foregroundColor(.orange)
                    } else if isMed {
                        Label("Approximate", systemImage: "waveform.path")
                            .font(.caption).foregroundColor(.steel)
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 5) {
                    RingGauge(value: confidence, color: accentColor)
                        .frame(width: 48, height: 48)
                    Text("Conf.")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundColor(.healthSub)
                }
            }
            .padding(16)

            if history.count >= 4 {
                Divider().padding(.horizontal, 16).opacity(0.6)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("LAST 60 SECONDS")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.2)
                            .foregroundColor(.healthSub)
                        if trend.isMeaningful && !isHeld {
                            trendChip
                        }
                        Spacer()
                        if let last = history.last {
                            Text("\(Int(last)) \(unit.lowercased())")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.healthSub)
                                .monospacedDigit()
                        }
                    }
                    SparklineView(values: history, color: accentColor)
                        .frame(height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(Color.surface)
        .cornerRadius(18)
        .shadow(color: Color.steel.opacity(0.10), radius: 10, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isLow ? Color.steelLight.opacity(0.30) : accentColor.opacity(0.20), lineWidth: 1)
        )
        .onAppear { pulsing = true }
    }

    private var trendChip: some View {
        HStack(spacing: 3) {
            Image(systemName: trend.icon)
                .font(.system(size: 9, weight: .bold))
            Text(trend.description)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundColor(accentColor)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(accentColor.opacity(0.10))
        .cornerRadius(4)
    }

    private func heldBadge(age: TimeInterval) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
            Text("Held · last good \(formatAge(age))")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(.healthSub)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.steelLight.opacity(0.25))
        .cornerRadius(6)
    }

    private func formatAge(_ age: TimeInterval) -> String {
        if age < 60 { return "\(Int(age))s ago" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        return "\(Int(age / 3600))h ago"
    }
}

// MARK: - SparklineView

struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let lo = values.min()!
            let hi = values.max()!
            let range = (hi - lo) > 1 ? (hi - lo) : 1

            func pt(_ i: Int) -> CGPoint {
                CGPoint(
                    x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height * CGFloat(1.0 - (values[i] - lo) / range) * 0.85 + size.height * 0.05
                )
            }

            // Filled area
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            fill.addLine(to: pt(0))
            for i in 1..<values.count { fill.addLine(to: pt(i)) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.10)))

            // Stroke
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<values.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(color.opacity(0.60)), lineWidth: 1.8)

            // End dot
            let last = pt(values.count - 1)
            ctx.fill(
                Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                with: .color(color)
            )
        }
    }
}

// MARK: - RingGauge

struct RingGauge: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.steelLight.opacity(0.30), lineWidth: 5)
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: min(0.75 * value, 0.75))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeInOut(duration: 1.0), value: value)
            Text("\(Int(value * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.healthSub)
                .monospacedDigit()
        }
    }
}
