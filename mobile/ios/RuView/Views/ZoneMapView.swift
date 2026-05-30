import SwiftUI

// MARK: - ZoneMapView

struct ZoneMapView: View {
    @ObservedObject var viewModel: SensingViewModel
    @State private var refreshTimer: Timer?

    private let gridColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                zoneGrid
                legendCard
                if let error = viewModel.zonesError {
                    errorBanner(message: error)
                }
            }
            .padding(16)
        }
        .navigationTitle("Zone Map")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                refreshButton
            }
        }
        .onAppear { startRefreshTimer() }
        .onDisappear { stopRefreshTimer() }
        .refreshable {
            await viewModel.refreshZones()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Room Overview")
                    .font(.headline)
                Text("2×2 zone layout")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                let totalPersons = viewModel.zones.reduce(0) { $0 + $1.personCount }
                Text("\(totalPersons)")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text("total persons")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Zone grid

    @ViewBuilder
    private var zoneGrid: some View {
        if viewModel.zonesLoading && viewModel.zones.isEmpty {
            loadingGrid
        } else if viewModel.zones.isEmpty {
            emptyState
        } else {
            // Show exactly 4 zones (zone_1 through zone_4), filling gaps
            let displayZones = makeDisplayZones()
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(displayZones) { zone in
                    ZoneTile(zone: zone, color: viewModel.zoneColor(personCount: zone.personCount))
                }
            }
        }
    }

    // MARK: - Legend

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color Legend")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                legendItem(color: Color(.systemGray5), label: "Empty (0)")
                legendItem(color: .blue.opacity(0.3), label: "1 person")
                legendItem(color: .orange.opacity(0.4), label: "2+ persons")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 20, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(.systemGray3), lineWidth: 0.5)
                )
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Loading / empty

    private var loadingGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            // Placeholder 2x2 grid
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(["Zone 1", "Zone 2", "Zone 3", "Zone 4"], id: \.self) { name in
                    ZoneTile(
                        zone: ZoneInfo(name: name, personCount: 0, status: "unknown"),
                        color: Color(.systemGray6)
                    )
                }
            }

            Text(viewModel.isConnected ? "No zone data yet" : "Connect to view zones")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Error

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Refresh

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refreshZones() }
        } label: {
            if viewModel.zonesLoading {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    private func startRefreshTimer() {
        Task { await viewModel.refreshZones() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await viewModel.refreshZones() }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Display zones helper

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
    let color: Color

    private var zoneDisplayName: String {
        zone.name
            .replacingOccurrences(of: "zone_", with: "Zone ")
            .capitalized
    }

    private var statusColor: Color {
        zone.status == "monitored" ? .blue : .secondary
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(zoneDisplayName)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            // Person count circle
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .stroke(Color(.systemGray3), lineWidth: 0.5)
                    )

                Text("\(zone.personCount)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(zone.personCount == 0 ? .secondary : .primary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4), value: zone.personCount)
            }

            Text(zone.personCount == 1 ? "person" : "persons")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            // Status badge
            Text(zone.status.capitalized)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.12))
                .cornerRadius(6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: zone.personCount)
    }
}
