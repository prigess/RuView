import SwiftUI

// MARK: - OccupancyView

struct OccupancyView: View {
    @ObservedObject var viewModel: SensingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Current Status",
                              trailing: viewModel.isLiveDataFlowing ? "Live · Updated just now" : "Waiting for data")
                personCountCard
                motionBadgeCard
                SectionHeader(title: "Details")
                classificationDetails
                SectionHeader(title: "Source")
                sourceCard
            }
            .padding(16)
        }
        .background(Color.steelPale.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Occupancy")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await viewModel.refreshNodes()
            await viewModel.refreshZones()
            await viewModel.refreshAdaptiveStatus()
        }
    }

    // MARK: - Person count

    private var personCountCard: some View {
        ZStack {
            SteelGradient.main
                .cornerRadius(20)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    LivePulseDot(color: .white, size: 7, active: viewModel.isLiveDataFlowing)
                    Text(viewModel.isLiveDataFlowing ? "LIVE" : "WAITING")
                        .font(.caption2).fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.85))
                        .tracking(1.5)
                }

                Text(String(viewModel.personCount))
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                    .frame(minWidth: 120)

                Text(viewModel.personCount == 1 ? "Person detected" : "Persons detected")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.85))

                if viewModel.personCountHistory.count >= 4 {
                    MiniSparkline(
                        values: viewModel.personCountHistory,
                        color: .white,
                        lineWidth: 1.8,
                        showEndDot: true
                    )
                    .frame(height: 28)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 8)
        }
        .shadow(color: Color.steel.opacity(0.40), radius: 14, x: 0, y: 7)
    }

    // MARK: - Motion badge

    private var motionBadgeCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(viewModel.motionColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Circle()
                        .fill(viewModel.motionColor)
                        .frame(width: 14, height: 14)
                }
                Text(viewModel.motionLevelDisplay)
                    .font(.title2).fontWeight(.semibold)
                    .foregroundColor(.healthText)
            }

            Text("Confidence: \(String(format: "%.0f%%", viewModel.overallConfidence * 100))")
                .font(.callout).foregroundColor(.healthSub)
                .monospacedDigit()

            confidenceBar(value: viewModel.overallConfidence)
        }
        .frame(maxWidth: .infinity)
        .ruCard()
    }

    // MARK: - Classification details

    private var classificationDetails: some View {
        VStack(spacing: 0) {
            detailRow(label: "Presence",
                      value: viewModel.snapshot?.classification.presence == true ? "Detected" : "Not detected",
                      icon: "person.fill")
            Divider().padding(.leading, 52)
            detailRow(label: "Motion level",
                      value: viewModel.motionLevel.replacingOccurrences(of: "_", with: " ").capitalized,
                      icon: "waveform")
            Divider().padding(.leading, 52)
            detailRow(label: "Last tick", value: viewModel.formattedTick, icon: "clock")
            Divider().padding(.leading, 52)
            detailRow(label: "Active nodes",
                      value: "\(viewModel.snapshot?.nodeFeatures.count ?? 0)",
                      icon: "antenna.radiowaves.left.and.right")
        }
        .background(Color.surface)
        .cornerRadius(16)
        .shadow(color: Color.steel.opacity(0.10), radius: 8, x: 0, y: 3)
    }

    private func detailRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.steel)
                .frame(width: 28, height: 28)
                .background(Color.steel.opacity(0.10))
                .cornerRadius(6)
            Text(label).foregroundColor(.healthSub)
            Spacer()
            Text(value).fontWeight(.medium).foregroundColor(.healthText)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: - Source card

    private var sourceCard: some View {
        HStack(spacing: 12) {
            LivePulseDot(
                color: viewModel.isDemoMode ? .orange : .steel,
                size: 9,
                active: viewModel.isLiveDataFlowing
            )
            Text(viewModel.isDemoMode ? "Demo Mode — simulated data" : "Live — ESP32 sensor data")
                .font(.callout).foregroundColor(.healthSub)
            Spacer()
            Text(viewModel.sourceLabel)
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(viewModel.isDemoMode ? Color.orange.opacity(0.12) : Color.steel.opacity(0.12))
                .foregroundColor(viewModel.isDemoMode ? .orange : .steel)
                .cornerRadius(6)
        }
        .ruCard()
    }

    // MARK: - Confidence bar

    private func confidenceBar(value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.steelLight.opacity(0.35))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SteelGradient.horizontal)
                    .frame(width: geo.size.width * CGFloat(value), height: 8)
                    .animation(.easeInOut(duration: 0.4), value: value)
            }
        }
        .frame(height: 8)
    }
}
