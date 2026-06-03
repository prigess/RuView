import SwiftUI

// MARK: - NodeHealthView

struct NodeHealthView: View {
    @ObservedObject var viewModel: SensingViewModel
    @State private var refreshTimer: Timer?

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SectionHeader(title: "Network Overview",
                              trailing: "\(viewModel.nodes.count) devices")
                summaryBar
                SectionHeader(title: "Sensor Nodes")
                nodeGrid
                if let error = viewModel.nodesError {
                    errorBanner(message: error)
                }
                restEndpointFooter
            }
            .padding(16)
        }
        .background(Color.steelPale.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Node Health")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { refreshButton }
        }
        .onAppear { startRefreshTimer() }
        .onDisappear { stopRefreshTimer() }
        .refreshable { await viewModel.refreshNodes() }
    }

    // MARK: - Summary bar

    private var summaryBar: some View {
        HStack(spacing: 0) {
            summaryItem(label: "Total", value: "\(viewModel.nodes.count)",
                        icon: "antenna.radiowaves.left.and.right", color: .steel)
            Divider().frame(height: 44)
            summaryItem(label: "Active",
                        value: "\(viewModel.nodes.filter { $0.status == "active" }.count)",
                        icon: "checkmark.circle.fill", color: .steel)
            Divider().frame(height: 44)
            summaryItem(label: "Stale",
                        value: "\(viewModel.nodes.filter { viewModel.isNodeStale($0) }.count)",
                        icon: "exclamationmark.triangle.fill", color: .orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.surface)
        .cornerRadius(16)
        .shadow(color: Color.steel.opacity(0.10), radius: 8, x: 0, y: 3)
    }

    private func summaryItem(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color).font(.caption)
            Text(value).font(.headline).fontWeight(.bold).foregroundColor(.healthText)
            Text(label).font(.caption2).foregroundColor(.healthSub)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Node grid

    @ViewBuilder
    private var nodeGrid: some View {
        if viewModel.nodesLoading && viewModel.nodes.isEmpty {
            loadingGrid
        } else if viewModel.nodes.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.nodes) { node in
                    NodeCard(
                        node: node,
                        viewModel: viewModel,
                        rssiHistory: viewModel.nodeRssiHistory[node.nodeId] ?? []
                    )
                }
            }
        }
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach([0, 1, 2, 3], id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.surface).frame(height: 130)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40)).foregroundColor(.steelLight)
            Text("No nodes found").font(.headline).foregroundColor(.healthSub)
            Text("Connect to the server to see ESP32 node status.")
                .font(.callout).foregroundColor(.healthSub).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(40)
        .ruCard()
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).font(.callout).foregroundColor(.orange)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.20), lineWidth: 1))
    }

    // MARK: - REST footer

    private var restEndpointFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "network").font(.caption2)
            Text("via REST · ")
                .font(.caption2)
            Text("GET /api/v1/nodes")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Spacer()
            Text("Refreshes every 5s")
                .font(.caption2)
        }
        .foregroundColor(.healthSub)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Toolbar

    private var refreshButton: some View {
        Button { Task { await viewModel.refreshNodes() } } label: {
            if viewModel.nodesLoading {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise").foregroundColor(.steel)
            }
        }
    }

    // MARK: - Timer

    private func startRefreshTimer() {
        Task { await viewModel.refreshNodes() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await viewModel.refreshNodes() }
        }
    }
    private func stopRefreshTimer() { refreshTimer?.invalidate(); refreshTimer = nil }
}

// MARK: - NodeCard

private struct NodeCard: View {
    let node: NodeStatus
    let viewModel: SensingViewModel
    let rssiHistory: [Double]

    private var barCount: Int { viewModel.rssiBarCount(rssi: node.rssiDbm) }
    private var isStale: Bool { viewModel.isNodeStale(node) }
    private var motionColor: Color {
        switch node.motionLevel {
        case "absent": return .healthSub
        case "present_still": return .steel
        case "present_moving": return .orange
        case "active": return .red
        default: return .healthSub
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    nodeIdBadge
                    Text(syntheticMac)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.healthSub)
                        .tracking(0.3)
                }
                Spacer()
                if isStale { staleBadge } else { activeDot }
            }

            radarTypeBadge

            HStack(alignment: .bottom, spacing: 6) {
                SignalBars(filledBars: barCount)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(String(format: "%.0f", node.rssiDbm)) dBm")
                        .font(.caption).fontWeight(.medium).foregroundColor(.healthText)
                        .monospacedDigit()
                    Text("Signal").font(.caption2).foregroundColor(.healthSub)
                }
            }

            if rssiHistory.count >= 4 {
                MiniSparkline(
                    values: rssiHistory,
                    color: signalSparklineColor,
                    lineWidth: 1.4,
                    showEndDot: false
                )
                .frame(height: 22)
            }

            Divider()

            HStack(spacing: 6) {
                Circle().fill(motionColor).frame(width: 8, height: 8)
                Text(node.motionLevel.motionLevelDisplay)
                    .font(.caption).foregroundColor(.healthSub)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption2).foregroundColor(.healthSub)
                Text(lastSeenText).font(.caption2)
                    .foregroundColor(isStale ? .orange : .healthSub)
            }
        }
        .padding(14)
        .background(Color.surface)
        .cornerRadius(14)
        .shadow(color: Color.steel.opacity(isStale ? 0.05 : 0.10), radius: 6, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isStale ? Color.orange.opacity(0.35) : Color.steel.opacity(0.08), lineWidth: 1.5)
        )
    }

    private var nodeIdBadge: some View {
        Text("Node \(node.nodeId)")
            .font(.callout).fontWeight(.semibold).foregroundColor(.healthText)
    }

    /// Deterministic MAC-style hardware identifier derived from node_id.
    /// Real ESP32 MACs come from the OUI block assigned by Espressif (D8:3A:DD).
    private var syntheticMac: String {
        let nid = node.nodeId
        return String(
            format: "D8:3A:DD:%02X:%02X:%02X",
            (nid * 17) & 0xFF,
            (nid * 113) & 0xFF,
            nid & 0xFF
        )
    }

    private var radarTypeBadge: some View {
        let (label, icon, accent) = radarInfo
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(accent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(accent.opacity(0.12))
        .cornerRadius(4)
    }

    private var radarInfo: (label: String, icon: String, accent: Color) {
        switch node.radarType.lowercased() {
        case "wifi-csi", "csi":
            return ("ESP32-S3 · WiFi CSI", "wifi", .steel)
        case "60ghz", "mmwave", "60ghz-mmwave":
            return ("MR60BHA2 · 60 GHz mmWave", "dot.radiowaves.up.forward", .lungTeal)
        case "24ghz", "ld2410":
            return ("LD2410 · 24 GHz Radar", "dot.radiowaves.forward", .lungTeal)
        default:
            return (node.radarType.isEmpty ? "Sensor" : node.radarType,
                    "antenna.radiowaves.left.and.right", .steel)
        }
    }

    private var staleBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
            Text("Stale").font(.caption2).fontWeight(.medium)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.orange.opacity(0.10)).cornerRadius(6)
    }

    private var activeDot: some View {
        HStack(spacing: 5) {
            LivePulseDot(color: .steel, size: 6, active: !isStale)
            Text("Active").font(.caption2).foregroundColor(.steel)
        }
    }

    private var signalSparklineColor: Color {
        switch barCount {
        case 3, 4: return .steel
        case 2:    return .orange
        default:   return .red
        }
    }

    private var lastSeenText: String {
        let ms = node.lastSeenMs
        if ms < 1000 { return "\(ms) ms ago" }
        return "\(ms / 1000)s ago"
    }
}

// MARK: - SignalBars

struct SignalBars: View {
    let filledBars: Int
    let totalBars: Int = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<totalBars, id: \.self) { index in
                let isFilled = index < filledBars
                RoundedRectangle(cornerRadius: 2)
                    .fill(isFilled ? barColor : Color.steelLight.opacity(0.35))
                    .frame(width: 5, height: CGFloat(6 + index * 5))
            }
        }
    }

    private var barColor: Color {
        switch filledBars {
        case 4: return .steel
        case 3: return .steel.opacity(0.75)
        case 2: return .orange
        case 1: return .red
        default: return .red
        }
    }
}
