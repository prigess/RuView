import SwiftUI

// MARK: - Expected dome roster
//
// 4-position dome layout (west / north / east / south) keyed by the node_id
// provisioned into each ESP32-S3's NVS. IPs are not used for identity — the
// firmware reports its own node_id in every UDP frame, and the Pi's
// /api/v1/nodes endpoint reports that id.
//
// Mirror of /root/RuView/data/esp32-node-ip-map.json on the Pi.

private struct ExpectedNode: Identifiable {
    let id: Int                  // canonical id for ForEach + display
    let acceptedIds: [Int]       // node_ids that count as "this position"
    let name: String             // "Node 1"
    let position: String         // "West"
    let mac: String
    let chip: String             // "ESP32-S3" or "ESP32-C6"
}

// Current dome roster is 3 ESP32-S3 nodes (west / north / east). The ESP32-C6
// that previously occupied the south position has been removed. Restore the
// 4th entry here when a south node is added back.
private let expectedRoster: [ExpectedNode] = [
    ExpectedNode(id: 1, acceptedIds: [1], name: "Node 1", position: "West",
                 mac: "e0:72:a1:d5:1d:4c", chip: "ESP32-S3"),
    ExpectedNode(id: 2, acceptedIds: [2], name: "Node 2", position: "North",
                 mac: "e0:72:a1:db:59:34", chip: "ESP32-S3"),
    ExpectedNode(id: 3, acceptedIds: [3], name: "Node 3", position: "East",
                 mac: "44:1b:f6:84:20:74", chip: "ESP32-S3"),
]

// MARK: - NodeHealthView

struct NodeHealthView: View {
    @ObservedObject var viewModel: SensingViewModel
    @State private var refreshTimer: Timer?

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var activeNodeMap: [Int: NodeStatus] {
        Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.nodeId, $0) })
    }

    /// First active node whose node_id matches any of the position's accepted ids.
    private func activeNode(for expected: ExpectedNode) -> NodeStatus? {
        for candidateId in expected.acceptedIds {
            if let n = activeNodeMap[candidateId] { return n }
        }
        return nil
    }

    /// Active node_ids that aren't accepted by any roster position.
    private var unmappedNodes: [NodeStatus] {
        let acceptedIds = Set(expectedRoster.flatMap { $0.acceptedIds })
        return viewModel.nodes.filter { !acceptedIds.contains($0.nodeId) }
    }

    private var onlineCount: Int {
        expectedRoster.filter { activeNode(for: $0) != nil }.count
    }

    private var offlineCount: Int {
        expectedRoster.count - onlineCount
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SectionHeader(title: "Dome Roster",
                              trailing: "\(onlineCount) / \(expectedRoster.count) online")
                summaryBar
                SectionHeader(title: "Positions")
                nodeGrid
                if !unmappedNodes.isEmpty {
                    SectionHeader(title: "Unmapped Nodes",
                                  trailing: "\(unmappedNodes.count) extra")
                    unmappedGrid
                }
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
            summaryItem(label: "Expected", value: "\(expectedRoster.count)",
                        icon: "antenna.radiowaves.left.and.right", color: .steel)
            Divider().frame(height: 44)
            summaryItem(label: "Online", value: "\(onlineCount)",
                        icon: "checkmark.circle.fill",
                        color: onlineCount == expectedRoster.count ? .steel
                              : onlineCount == 0 ? .orange : .steel)
            Divider().frame(height: 44)
            summaryItem(label: "Offline", value: "\(offlineCount)",
                        icon: "exclamationmark.triangle.fill",
                        color: offlineCount == 0 ? .healthSub : .orange)
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

    // MARK: - Node grid (4 dome positions, always shown)

    @ViewBuilder
    private var nodeGrid: some View {
        if viewModel.nodesLoading && viewModel.nodes.isEmpty && onlineCount == 0 {
            loadingGrid
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(expectedRoster) { expected in
                    if let active = activeNode(for: expected) {
                        NodeCard(
                            node: active,
                            viewModel: viewModel,
                            rssiHistory: viewModel.nodeRssiHistory[active.nodeId] ?? [],
                            positionLabel: expected.position,
                            chipLabel: expected.chip
                        )
                    } else {
                        OfflineNodeCard(expected: expected)
                    }
                }
            }
        }
    }

    // Active nodes the server reports that aren't part of the dome roster
    // (e.g., legacy Node 7 streaming before its re-provisioning to Node 4).
    private var unmappedGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(unmappedNodes) { node in
                NodeCard(
                    node: node,
                    viewModel: viewModel,
                    rssiHistory: viewModel.nodeRssiHistory[node.nodeId] ?? [],
                    positionLabel: "Unassigned",
                    chipLabel: "ESP32"
                )
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
    var positionLabel: String? = nil   // e.g., "West", "North"
    var chipLabel: String = "ESP32"    // "ESP32-S3" | "ESP32-C6" — from roster, not server

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
                    HStack(spacing: 6) {
                        nodeIdBadge
                        if let pos = positionLabel {
                            Text(pos.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.0)
                                .foregroundColor(.steel)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.steel.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
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
        // chipLabel comes from the dome roster (e.g., "ESP32-S3", "ESP32-C6").
        // Server's radar_type field describes the active sensor capability.
        switch node.radarType.lowercased() {
        case "wifi-csi", "csi", "none", "":
            return ("\(chipLabel) · WiFi CSI", "wifi", .steel)
        case "60ghz", "mmwave", "60ghz-mmwave":
            return ("\(chipLabel) · 60 GHz mmWave", "dot.radiowaves.up.forward", .lungTeal)
        case "24ghz", "ld2410":
            return ("\(chipLabel) · 24 GHz Radar", "dot.radiowaves.forward", .lungTeal)
        default:
            return ("\(chipLabel) · \(node.radarType)", "antenna.radiowaves.left.and.right", .steel)
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

// MARK: - OfflineNodeCard
//
// Placeholder card shown when a dome-roster position has no active node
// reporting at the server. Visually muted with a dashed border so it's
// obvious at a glance that it's not live.

private struct OfflineNodeCard: View {
    let expected: ExpectedNode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(expected.name)
                            .font(.callout).fontWeight(.semibold)
                            .foregroundColor(.healthSub)
                        Text(expected.position.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.0)
                            .foregroundColor(.healthSub)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.healthSub.opacity(0.12))
                            .cornerRadius(4)
                    }
                    Text(expected.mac)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.healthSub.opacity(0.6))
                        .tracking(0.3)
                }
                Spacer()
                offlineBadge
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 28))
                    .foregroundColor(.steelLight)
                Text(expected.chip)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.healthSub)
                    .tracking(0.5)
                Text("Awaiting connection")
                    .font(.caption2)
                    .foregroundColor(.healthSub)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minHeight: 200, alignment: .top)
        .background(Color.surface.opacity(0.55))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.healthSub.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var offlineBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.healthSub).frame(width: 7, height: 7)
            Text("Offline").font(.caption2).fontWeight(.medium)
        }
        .foregroundColor(.healthSub)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.healthSub.opacity(0.10))
        .cornerRadius(6)
    }
}
