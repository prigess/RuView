import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var viewModel: SensingViewModel
    @AppStorage("deviceHost") private var deviceHost: String = "192.168.8.11"
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    @State private var showingTrainingWizard: Bool = false
    @State private var showingDeviceSetup: Bool = false
    @State private var showingAbout: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                NavigationView {
                    OccupancyView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem { Label("Occupancy", systemImage: "person.3.fill") }
                .tag(0)

                NavigationView {
                    VitalSignsView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem { Label("Vitals", systemImage: "heart.fill") }
                .tag(1)

                NavigationView {
                    SkeletonView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem { Label("Skeleton", systemImage: "figure.walk") }
                .tag(2)

                NavigationView {
                    NodeHealthView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem { Label("Nodes", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(3)

                NavigationView {
                    ZoneMapView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem { Label("Zones", systemImage: "map.fill") }
                .tag(4)
            }
            .tint(.steel)
            // Make the iOS 26 floating tab bar opaque so content doesn't
            // scroll visibly behind it.
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color.steelPale, for: .tabBar)

            VStack(spacing: 0) {
                // The connection banners reflect the main sensing-server link.
                // When the LD2450 radar is streaming directly we have live data
                // regardless of that server, so suppress the banners — otherwise
                // "Signal lost" is misleading while targets are tracking fine.
                if viewModel.ld2450Reachable {
                    EmptyView()
                } else if viewModel.isSignalLost {
                    signalLostBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if viewModel.isDemoMode {
                    demoBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if viewModel.showDisconnectedBanner {
                    disconnectedBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: viewModel.showDisconnectedBanner)
            .animation(.easeInOut(duration: 0.35), value: viewModel.isSignalLost)
            .animation(.easeInOut(duration: 0.35), value: viewModel.isDemoMode)
        }
        .sheet(isPresented: $showingTrainingWizard) {
            TrainingWizardView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingDeviceSetup) {
            deviceSetupSheet
        }
        .sheet(isPresented: $showingAbout) {
            AboutSheetView(viewModel: viewModel)
        }
    }

    // MARK: - Banners

    private var signalLostBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").foregroundColor(.white)
            Text("Signal lost — waiting for data")
                .font(.callout).fontWeight(.medium).foregroundColor(.white)
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.steelDark.opacity(0.95))
        .ignoresSafeArea(edges: .top)
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill").foregroundColor(.white)
            Text("Demo Mode — simulated sensor data")
                .font(.callout).fontWeight(.medium).foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.9))
        .ignoresSafeArea(edges: .top)
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 8) {
            if viewModel.connectionError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.white)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.7)
            }
            Text(viewModel.connectionError ?? "Connecting to \(deviceHost)…")
                .font(.callout).fontWeight(.medium).foregroundColor(.white).lineLimit(1)
            Spacer()
            Button { showingDeviceSetup = true } label: {
                Text("Change")
                    .font(.caption).fontWeight(.semibold).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.25)).cornerRadius(6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(SteelGradient.horizontal)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Toolbar

    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Section {
                    Button { showingTrainingWizard = true } label: {
                        Label("Training Wizard", systemImage: "graduationcap")
                    }
                    Button { showingDeviceSetup = true } label: {
                        Label("Change Server", systemImage: "network")
                    }
                    Button { showingAbout = true } label: {
                        Label("About RuView", systemImage: "info.circle")
                    }
                }
                Section("Appearance") {
                    appearanceButton(.system)
                    appearanceButton(.light)
                    appearanceButton(.dark)
                }
                Section {
                    Button(role: .destructive) {
                        viewModel.disconnect()
                        showingDeviceSetup = true
                    } label: {
                        Label("Disconnect", systemImage: "wifi.slash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundColor(.steel)
            }
        }
    }

    private func appearanceButton(_ mode: AppearanceMode) -> some View {
        let current = AppearanceMode(rawValue: appearanceModeRaw) ?? .system
        return Button {
            appearanceModeRaw = mode.rawValue
        } label: {
            // Active mode shows a checkmark instead of its native icon so the
            // selected state is obvious at a glance.
            Label(mode.label, systemImage: mode == current ? "checkmark" : mode.icon)
        }
    }

    private var deviceSetupSheet: some View {
        DeviceSetupView { newHost in
            showingDeviceSetup = false
            viewModel.connect(host: newHost)
        }
    }
}
