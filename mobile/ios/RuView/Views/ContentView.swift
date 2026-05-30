import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var viewModel: SensingViewModel
    @AppStorage("deviceHost") private var deviceHost: String = ""
    @State private var selectedTab: Int = 0
    @State private var showingTrainingWizard: Bool = false
    @State private var showingDeviceSetup: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                NavigationView {
                    OccupancyView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem {
                    Label("Occupancy", systemImage: "person.3.fill")
                }
                .tag(0)

                NavigationView {
                    VitalSignsView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem {
                    Label("Vitals", systemImage: "heart.fill")
                }
                .tag(1)

                NavigationView {
                    SkeletonView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem {
                    Label("Skeleton", systemImage: "figure.walk")
                }
                .tag(2)

                NavigationView {
                    NodeHealthView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem {
                    Label("Nodes", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(3)

                NavigationView {
                    ZoneMapView(viewModel: viewModel)
                        .toolbar { settingsToolbarItem }
                }
                .tabItem {
                    Label("Zones", systemImage: "map.fill")
                }
                .tag(4)
            }

            // Connection status banner
            VStack(spacing: 0) {
                if viewModel.isSignalLost {
                    signalLostBanner
                } else if viewModel.isDemoMode {
                    demoBanner
                } else if !viewModel.isConnected {
                    disconnectedBanner
                }
            }
            .animation(.easeInOut(duration: 0.3), value: viewModel.isConnected)
            .animation(.easeInOut(duration: 0.3), value: viewModel.isSignalLost)
        }
        .sheet(isPresented: $showingTrainingWizard) {
            TrainingWizardView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingDeviceSetup) {
            deviceSetupSheet
        }
    }

    // MARK: - Banners

    private var signalLostBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundColor(.white)
            Text("Signal lost — waiting for data")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundColor(.white)
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.9))
        .ignoresSafeArea(edges: .top)
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
                .foregroundColor(.white)
            Text("Demo Mode — simulated sensor data")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.9))
        .ignoresSafeArea(edges: .top)
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 8) {
            if viewModel.connectionError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.white)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.7)
            }

            Text(viewModel.connectionError ?? "Connecting to \(deviceHost)…")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            Button {
                showingDeviceSetup = true
            } label: {
                Text("Change")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.25))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGray).opacity(0.9))
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Toolbar

    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showingTrainingWizard = true
                } label: {
                    Label("Training Wizard", systemImage: "graduationcap")
                }

                Button {
                    showingDeviceSetup = true
                } label: {
                    Label("Change Server", systemImage: "network")
                }

                Divider()

                Button(role: .destructive) {
                    viewModel.disconnect()
                    showingDeviceSetup = true
                } label: {
                    Label("Disconnect", systemImage: "wifi.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Device setup sheet

    private var deviceSetupSheet: some View {
        DeviceSetupView { newHost in
            showingDeviceSetup = false
            viewModel.connect(host: newHost)
        }
    }
}
