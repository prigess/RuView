import SwiftUI

// MARK: - VitalSignsView

struct VitalSignsView: View {
    @ObservedObject var viewModel: SensingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if viewModel.isMeasuring {
                    measuringBanner
                }

                if let vitals = viewModel.snapshot?.vitalSigns {
                    heartRateCard(vitals: vitals)
                    breathingCard(vitals: vitals)
                    signalQualityCard(vitals: vitals)
                    confidenceDetailsCard(vitals: vitals)
                } else {
                    noDataCard
                }
            }
            .padding(16)
        }
        .navigationTitle("Vital Signs")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Measuring banner

    private var measuringBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Measuring…")
                    .fontWeight(.medium)
                Text("Vital signs take 30 seconds to stabilize after connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Heart rate card

    private func heartRateCard(vitals: VitalSigns) -> some View {
        VitalCard(
            icon: "heart.fill",
            iconColor: .red,
            title: "Heart Rate",
            value: viewModel.formattedHeartRate(vitals: vitals),
            unit: "BPM",
            confidence: vitals.heartbeatConfidence,
            waveformColor: .red
        )
    }

    // MARK: - Breathing card

    private func breathingCard(vitals: VitalSigns) -> some View {
        VitalCard(
            icon: "lungs.fill",
            iconColor: .teal,
            title: "Breathing Rate",
            value: viewModel.formattedBreathing(vitals: vitals),
            unit: "BPM",
            confidence: vitals.breathingConfidence,
            waveformColor: .teal
        )
    }

    // MARK: - Signal quality

    private func signalQualityCard(vitals: VitalSigns) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Signal Quality", systemImage: "waveform.path.ecg")
                .font(.headline)

            HStack(spacing: 16) {
                signalQualityBars(quality: vitals.signalQuality)

                VStack(alignment: .leading, spacing: 2) {
                    Text(signalQualityLabel(vitals.signalQuality))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(signalQualityColor(vitals.signalQuality))

                    Text("\(String(format: "%.0f%%", vitals.signalQuality * 100)) signal strength")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                        .frame(height: 10)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: signalQualityGradient(vitals.signalQuality),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(vitals.signalQuality), height: 10)
                        .animation(.easeInOut(duration: 0.5), value: vitals.signalQuality)
                }
            }
            .frame(height: 10)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Confidence details

    private func confidenceDetailsCard(vitals: VitalSigns) -> some View {
        VStack(spacing: 0) {
            confidenceRow(
                label: "Heart rate confidence",
                value: vitals.heartbeatConfidence,
                icon: "heart.fill",
                color: .red
            )
            Divider().padding(.leading, 44)
            confidenceRow(
                label: "Breathing confidence",
                value: vitals.breathingConfidence,
                icon: "lungs.fill",
                color: .teal
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func confidenceRow(label: String, value: Double, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1))
                .cornerRadius(6)

            Text(label)
                .foregroundColor(.secondary)

            Spacer()

            Text(confidenceLabel(value))
                .fontWeight(.medium)
                .foregroundColor(confidenceLabelColor(value))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - No data

    private var noDataCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No vital sign data")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Connect to a sensing server to see heart rate and breathing data.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Helpers

    private func signalQualityLabel(_ quality: Double) -> String {
        if quality >= 0.8 { return "Excellent" }
        if quality >= 0.6 { return "Good" }
        if quality >= 0.4 { return "Fair" }
        if quality >= 0.2 { return "Poor" }
        return "Very poor"
    }

    private func signalQualityColor(_ quality: Double) -> Color {
        if quality >= 0.6 { return .green }
        if quality >= 0.4 { return .orange }
        return .red
    }

    private func signalQualityGradient(_ quality: Double) -> [Color] {
        if quality >= 0.6 { return [.green.opacity(0.7), .green] }
        if quality >= 0.4 { return [.orange.opacity(0.7), .orange] }
        return [.red.opacity(0.7), .red]
    }

    private func signalQualityBars(quality: Double) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach([0, 1, 2, 3], id: \.self) { index in
                let filled = quality > Double(index) * 0.25
                RoundedRectangle(cornerRadius: 2)
                    .fill(filled ? signalQualityColor(quality) : Color(.systemGray4))
                    .frame(width: 6, height: CGFloat(8 + index * 4))
            }
        }
    }

    private func confidenceLabel(_ value: Double) -> String {
        if value >= 0.6 { return "High" }
        if value >= 0.3 { return "Medium" }
        return "Low"
    }

    private func confidenceLabelColor(_ value: Double) -> Color {
        if value >= 0.6 { return .green }
        if value >= 0.3 { return .orange }
        return .red
    }
}

// MARK: - VitalCard

private struct VitalCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let unit: String
    let confidence: Double
    let waveformColor: Color

    private var isLowConfidence: Bool { confidence < 0.3 }
    private var isMediumConfidence: Bool { confidence >= 0.3 && confidence < 0.6 }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(iconColor)
                .frame(width: 48, height: 48)
                .background(iconColor.opacity(0.1))
                .cornerRadius(12)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(isLowConfidence ? .secondary : .primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: value)

                    if value != "–" {
                        Text(unit)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }

                confidenceIndicator
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isLowConfidence ? Color.clear : iconColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var confidenceIndicator: some View {
        HStack(spacing: 4) {
            if isLowConfidence {
                Label("Low signal", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if isMediumConfidence {
                Label("Approximate", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Label("High confidence", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }
}
