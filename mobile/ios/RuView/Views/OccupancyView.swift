import SwiftUI

// MARK: - OccupancyView

struct OccupancyView: View {
    @ObservedObject var viewModel: SensingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                personCountCard
                motionBadgeCard
                classificationDetails
                sourceCard
            }
            .padding(16)
        }
        .navigationTitle("Occupancy")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Person Count

    private var personCountCard: some View {
        VStack(spacing: 8) {
            Text(String(viewModel.personCount))
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundColor(viewModel.personCount == 0 ? .secondary : .primary)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4), value: viewModel.personCount)

            Text(viewModel.personCount == 1 ? "Person detected" : "Persons detected")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Motion Badge

    private var motionBadgeCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Circle()
                    .fill(viewModel.motionColor)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(viewModel.motionColor.opacity(0.3), lineWidth: 4)
                            .scaleEffect(1.6)
                    )

                Text(viewModel.motionLevelDisplay)
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text("Confidence: \(String(format: "%.0f%%", viewModel.overallConfidence * 100))")
                .font(.callout)
                .foregroundColor(.secondary)

            confidenceBar(value: viewModel.overallConfidence)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(viewModel.motionColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(viewModel.motionColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Classification details

    private var classificationDetails: some View {
        VStack(spacing: 0) {
            detailRow(label: "Presence", value: viewModel.snapshot?.classification.presence == true ? "Detected" : "Not detected", icon: "person.fill")
            Divider().padding(.leading, 44)
            detailRow(label: "Motion level", value: viewModel.motionLevel.replacingOccurrences(of: "_", with: " ").capitalized, icon: "waveform")
            Divider().padding(.leading, 44)
            detailRow(label: "Last tick", value: viewModel.formattedTick, icon: "clock")
            Divider().padding(.leading, 44)
            detailRow(label: "Active nodes", value: "\(viewModel.snapshot?.nodeFeatures.count ?? 0)", icon: "antenna.radiowaves.left.and.right")
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func detailRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)

            Text(label)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Source card

    private var sourceCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.isDemoMode ? .orange : .green)
                .frame(width: 10, height: 10)

            Text(viewModel.isDemoMode ? "Demo Mode — simulated data" : "Live — ESP32 sensor data")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Text(viewModel.sourceLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(viewModel.isDemoMode ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                .foregroundColor(viewModel.isDemoMode ? .orange : .green)
                .cornerRadius(6)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Confidence bar

    private func confidenceBar(value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(height: 8)

                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [viewModel.motionColor.opacity(0.7), viewModel.motionColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(value), height: 8)
                    .animation(.easeInOut(duration: 0.4), value: value)
            }
        }
        .frame(height: 8)
    }
}
