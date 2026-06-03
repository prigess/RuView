import SwiftUI

// MARK: - VitalSignsView

struct VitalSignsView: View {
    @ObservedObject var viewModel: SensingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.isMeasuring {
                    measuringBanner
                }
                if let vitals = viewModel.snapshot?.vitalSigns {
                    SectionHeader(title: "Vital Signs", trailing: liveTimestamp)
                    heartRateCard(vitals: vitals)
                    breathingCard(vitals: vitals)
                    SectionHeader(title: "Signal")
                    signalQualityCard(vitals: vitals)
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
            Text("No vital sign data")
                .font(.headline).foregroundColor(.healthSub)
            Text("Connect to a sensing server to see heart rate and breathing data.")
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
