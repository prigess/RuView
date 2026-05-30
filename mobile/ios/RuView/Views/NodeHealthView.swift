import SwiftUI

// MARK: - NodeHealthView

struct NodeHealthView: View {
    @ObservedObject var viewModel: SensingViewModel
    @State private var refreshTimer: Timer?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryBar
                nodeGrid
                if let error = viewModel.nodesError {
                    errorBanner(message: error)
                }
            }
            .padding(16)
        }
        .navigationTitle("Node Health")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                refreshButton
            }
        }
        .onAppear { startRefreshTimer() }
        .onDisappear { stopRefreshTimer() }
        .refreshable {
            await viewModel.refreshNodes()
        }
    }

    // MARK: - Summary bar

    private var summaryBar: some View {
        HStack(spacing: 0) {
            summaryItem(
                label: "Total nodes",
                value: "\(viewModel.nodes.count)",
                icon: "antenna.radiowaves.left.and.right",
                color: .blue
            )
            Divider().frame(height: 40)
            summaryItem(
                label: "Active",
                value: "\(viewModel.nodes.filter { $0.status == "active" }.count)",
                icon: "checkmark.circle.fill",
                color: .green
            )
            Divider().frame(height: 40)
            summaryItem(
                label: "Stale",
                value: "\(viewModel.nodes.filter { viewModel.isNodeStale($0) }.count)",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func summaryItem(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
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
                    NodeCard(node: node, viewModel: viewModel)
                }
            }
        }
    }

    // MARK: - Loading / empty states

    private var loadingGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 130)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No nodes found")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Connect to the server to see ESP32 node status.")
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

    // MARK: - Error banner

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

    // MARK: - Toolbar

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refreshNodes() }
        } label: {
            if viewModel.nodesLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
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

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - NodeCard

private struct NodeCard: View {
    let node: NodeStatus
    let viewModel: SensingViewModel

    private var barCount: Int { viewModel.rssiBarCount(rssi: node.rssiDbm) }
    private var isStale: Bool { viewModel.isNodeStale(node) }
    private var motionColor: Color {
        switch node.motionLevel {
        case "absent": return .gray
        case "present_still": return .blue
        case "present_moving": return .orange
        case "active": return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                nodeIdBadge
                Spacer()
                if isStale {
                    staleBadge
                } else {
                    activeDot
                }
            }

            // RSSI bars
            HStack(alignment: .bottom, spacing: 4) {
                SignalBars(filledBars: barCount)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(String(format: "%.0f", node.rssiDbm)) dBm")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Signal")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Motion level
            HStack(spacing: 6) {
                Circle()
                    .fill(motionColor)
                    .frame(width: 8, height: 8)
                Text(node.motionLevel.motionLevelDisplay)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            // Last seen
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(lastSeenText)
                    .font(.caption2)
                    .foregroundColor(isStale ? .orange : .secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isStale ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
    }

    private var nodeIdBadge: some View {
        Text("Node \(node.nodeId)")
            .font(.callout)
            .fontWeight(.semibold)
    }

    private var staleBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("Stale")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    private var activeDot: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
            Text("Active")
                .font(.caption2)
                .foregroundColor(.green)
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
                    .fill(isFilled ? barColor : Color(.systemGray4))
                    .frame(width: 5, height: CGFloat(6 + index * 5))
            }
        }
    }

    private var barColor: Color {
        switch filledBars {
        case 4: return .green
        case 3: return .green.opacity(0.8)
        case 2: return .orange
        case 1: return .red
        default: return .red
        }
    }
}
