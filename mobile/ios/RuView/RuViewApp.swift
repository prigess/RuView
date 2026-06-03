import SwiftUI

// MARK: - RuViewApp

@main
@MainActor
struct RuViewApp: App {
    @AppStorage("deviceHost") private var deviceHost: String = ""
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @StateObject private var viewModel = SensingViewModel()

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if deviceHost.isEmpty {
            DeviceSetupView { host in
                viewModel.connect(host: host)
            }
        } else {
            ContentView(viewModel: viewModel)
                .onAppear {
                    // Auto-connect on launch if host is already saved
                    viewModel.connect(host: deviceHost)
                }
        }
    }
}
