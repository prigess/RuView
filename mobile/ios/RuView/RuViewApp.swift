import SwiftUI

// MARK: - RuViewApp

@main
struct RuViewApp: App {
    @AppStorage("deviceHost") private var deviceHost: String = ""
    @StateObject private var viewModel = SensingViewModel()

    var body: some Scene {
        WindowGroup {
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
}
