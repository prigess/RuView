import SwiftUI

// MARK: - AboutSheetView

struct AboutSheetView: View {
    @ObservedObject var viewModel: SensingViewModel
    @AppStorage("deviceHost") private var deviceHost: String = "192.168.8.11"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    deviceSection
                    classifierSection
                    appSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Color.steelPale.ignoresSafeArea())
            .navigationTitle("About RuView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(.steel)
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SteelGradient.main)
                    .frame(width: 88, height: 88)
                    .shadow(color: Color.steel.opacity(0.30), radius: 12, x: 0, y: 6)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
            }
            VStack(spacing: 4) {
                Text("RuView Sensing")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.healthText)
                Text("WiFi-based passive monitoring")
                    .font(.callout)
                    .foregroundColor(.healthSub)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Device

    private var deviceSection: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Device")
                .padding(.leading, 4).padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                infoRow("IP Address", deviceHost.isEmpty ? "—" : deviceHost,
                        icon: "network", accent: .steel)
                Divider().padding(.leading, 52)
                infoRow("Data Source", sourceLabel,
                        icon: sourceIcon, accent: sourceAccent)
                Divider().padding(.leading, 52)
                infoRow("Active Nodes", "\(viewModel.directActiveNodes) of 4",
                        icon: "dot.radiowaves.up.forward", accent: .steel)
                Divider().padding(.leading, 52)
                infoRow("Live Tick", viewModel.formattedTick,
                        icon: "waveform.path.ecg", accent: .steel)
                Divider().padding(.leading, 52)
                infoRow("Connection",
                        viewModel.isConnected ? "Connected" : "Disconnected",
                        icon: viewModel.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        accent: viewModel.isConnected ? .steel : .orange)
            }
            .background(Color.surface)
            .cornerRadius(14)
        }
    }

    private var sourceLabel: String {
        guard let src = viewModel.snapshot?.source else { return "—" }
        switch src {
        case "esp32":    return "ESP32 (Live)"
        case "simulate": return "Simulation"
        case "file":     return "Replay"
        default:         return src
        }
    }
    private var sourceIcon: String {
        viewModel.isDemoMode ? "theatermasks.fill" : "antenna.radiowaves.left.and.right"
    }
    private var sourceAccent: Color {
        viewModel.isDemoMode ? .orange : .steel
    }

    // MARK: - Classifier

    private var classifierSection: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Classifier")
                .padding(.leading, 4).padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                infoRow("Adaptive Model",
                        viewModel.adaptiveStatus?.loaded == true ? "Loaded" : "Not loaded",
                        icon: "brain", accent: .steel)
                if let acc = viewModel.adaptiveStatus?.accuracy {
                    Divider().padding(.leading, 52)
                    infoRow("Accuracy", String(format: "%.0f%%", acc * 100),
                            icon: "checkmark.seal", accent: .steel)
                }
                if let frames = viewModel.adaptiveStatus?.trainedFrames {
                    Divider().padding(.leading, 52)
                    infoRow("Trained Frames", "\(frames)",
                            icon: "rectangle.stack", accent: .steel)
                }
                if let classes = viewModel.adaptiveStatus?.classes, !classes.isEmpty {
                    Divider().padding(.leading, 52)
                    infoRow("Classes", "\(classes.count) labels",
                            icon: "tag", accent: .steel)
                }
                Divider().padding(.leading, 52)
                infoRow("Calibration",
                        viewModel.calibrationStatus?.status.capitalized ?? "Unknown",
                        icon: "scope", accent: .steel)
            }
            .background(Color.surface)
            .cornerRadius(14)
        }
    }

    // MARK: - App

    private var appSection: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "App")
                .padding(.leading, 4).padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                infoRow("Version", versionString, icon: "app.badge", accent: .steel)
                Divider().padding(.leading, 52)
                infoRow("Build", buildNumber, icon: "hammer", accent: .steel)
                Divider().padding(.leading, 52)
                infoRow("Platform", "iOS \(UIDevice.current.systemVersion)",
                        icon: "iphone", accent: .steel)
            }
            .background(Color.surface)
            .cornerRadius(14)
        }
    }

    private func infoRow(_ label: String, _ value: String, icon: String, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.12))
                .cornerRadius(6)
            Text(label).foregroundColor(.healthSub)
            Spacer()
            Text(value)
                .fontWeight(.medium).foregroundColor(.healthText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
