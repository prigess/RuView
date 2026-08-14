import SwiftUI

// MARK: - ZoneMapView

struct ZoneMapView: View {
    @ObservedObject var viewModel: SensingViewModel
    @State private var refreshTimer: Timer?

    private let gridColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SectionHeader(title: "Room Layout",
                              trailing: viewModel.directDataLive ? "Live" : "Idle")
                headerCard
                SectionHeader(title: "Zones")
                zoneGrid
                SectionHeader(title: "Legend")
                legendCard
                if let error = viewModel.zonesError {
                    errorBanner(message: error)
                }
            }
            .padding(16)
        }
        .background(Color.steelPale.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Zone Map")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { refreshButton }
        }
        .onAppear { startRefreshTimer() }
        .onDisappear { stopRefreshTimer() }
        .refreshable { await viewModel.refreshZones() }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LivePulseDot(color: .steel, size: 6, active: viewModel.directDataLive)
                    Text("Room Overview").font(.headline).foregroundColor(.healthText)
                }
                Text("2×2 zone layout").font(.caption).foregroundColor(.healthSub)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                let totalPersons = viewModel.zones.reduce(0) { $0 + $1.personCount }
                Text("\(totalPersons)")
                    .font(.title).fontWeight(.bold)
                    .foregroundColor(.steel)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text("total persons").font(.caption).foregroundColor(.healthSub)
            }
        }
        .ruCard()
    }

    // MARK: - Zone grid

    @ViewBuilder
    private var zoneGrid: some View {
        if viewModel.zonesLoading && viewModel.zones.isEmpty {
            loadingGrid
        } else if viewModel.zones.isEmpty {
            emptyState
        } else {
            let displayZones = makeDisplayZones()
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(displayZones) { zone in
                    ZoneTile(zone: zone, occupancyColor: zoneOccupancyColor(personCount: zone.personCount))
                }
            }
        }
    }

    private func zoneOccupancyColor(personCount: Int) -> Color {
        switch personCount {
        case 0: return Color.steelPale
        case 1: return Color.steel.opacity(0.22)
        default: return Color.steel.opacity(0.52)
        }
    }

    // MARK: - Legend

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color Legend")
                .font(.subheadline).fontWeight(.medium).foregroundColor(.healthSub)
            HStack(spacing: 20) {
                legendItem(color: Color.steelPale, label: "Empty (0)")
                legendItem(color: Color.steel.opacity(0.22), label: "1 person")
                legendItem(color: Color.steel.opacity(0.52), label: "2+ persons")
            }
        }
        .ruCard()
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 20, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.steelLight.opacity(0.5), lineWidth: 0.5))
            Text(label).font(.caption).foregroundColor(.healthSub)
        }
    }

    // MARK: - Loading / empty

    private var loadingGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach([0, 1, 2, 3], id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.surface).frame(height: 120)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(["Zone 1", "Zone 2", "Zone 3", "Zone 4"], id: \.self) { name in
                    ZoneTile(
                        zone: ZoneInfo(name: name, personCount: 0, status: "unknown"),
                        occupancyColor: Color.steelPale
                    )
                }
            }
            Text(viewModel.isConnected ? "No zone data yet" : "Connect to view zones")
                .font(.callout).foregroundColor(.healthSub)
        }
    }

    // MARK: - Error

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).font(.callout).foregroundColor(.orange)
            Spacer()
        }
        .padding(12).background(Color.orange.opacity(0.08)).cornerRadius(10)
    }

    // MARK: - Refresh

    private var refreshButton: some View {
        Button { Task { await viewModel.refreshZones() } } label: {
            if viewModel.zonesLoading {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise").foregroundColor(.steel)
            }
        }
    }

    private func startRefreshTimer() {
        Task { await viewModel.refreshZones() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await viewModel.refreshZones() }
        }
    }
    private func stopRefreshTimer() { refreshTimer?.invalidate(); refreshTimer = nil }

    private func makeDisplayZones() -> [ZoneInfo] {
        let zoneNames = ["zone_1", "zone_2", "zone_3", "zone_4"]
        let existing = Dictionary(uniqueKeysWithValues: viewModel.zones.map { ($0.name, $0) })
        return zoneNames.map { name in
            existing[name] ?? ZoneInfo(name: name, personCount: 0, status: "clear")
        }
    }
}

// MARK: - ZoneTile

private struct ZoneTile: View {
    let zone: ZoneInfo
    let occupancyColor: Color

    private var zoneDisplayName: String {
        zone.name.replacingOccurrences(of: "zone_", with: "Zone ").capitalized
    }

    private var isMonitored: Bool { zone.status == "monitored" }

    var body: some View {
        VStack(spacing: 8) {
            Text(zoneDisplayName)
                .font(.callout).fontWeight(.semibold).foregroundColor(.healthText)

            Spacer()

            ZStack {
                Circle()
                    .fill(occupancyColor)
                    .frame(width: 60, height: 60)
                    .overlay(Circle().stroke(Color.steel.opacity(0.20), lineWidth: 1))

                Text("\(zone.personCount)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(zone.personCount == 0 ? .healthSub : .steelDark)
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }

            Text(zone.personCount == 1 ? "person" : "persons")
                .font(.caption2).foregroundColor(.healthSub)

            Spacer()

            Text(zone.status.capitalized)
                .font(.caption2).fontWeight(.medium)
                .foregroundColor(isMonitored ? .steel : .healthSub)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((isMonitored ? Color.steel : Color.healthSub).opacity(0.10))
                .cornerRadius(6)
        }
        .frame(maxWidth: .infinity).frame(height: 150)
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(Color.surface)
        .cornerRadius(16)
        .shadow(color: Color.steel.opacity(0.10), radius: 8, x: 0, y: 3)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(zone.personCount > 0 ? Color.steel.opacity(0.20) : Color.steelLight.opacity(0.30), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.3), value: zone.personCount)
    }
}
