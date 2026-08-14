import SwiftUI

// MARK: - DeviceSetupView

struct DeviceSetupView: View {
    @AppStorage("deviceHost") private var deviceHost: String = "192.168.8.11"
    @State private var inputHost: String = ""
    @State private var isChecking: Bool = false
    @State private var errorMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    let onConnected: (String) -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    inputSection
                    connectButton
                    if let error = errorMessage {
                        errorBanner(message: error)
                    }
                    helpSection
                }
                .padding(24)
            }
            .background(Color.steelPale.ignoresSafeArea())
            .navigationTitle("Connect to RuView")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            inputHost = deviceHost.isEmpty ? "" : deviceHost
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SteelGradient.main)
                    .frame(width: 90, height: 90)
                    .shadow(color: Color.steel.opacity(0.35), radius: 12, x: 0, y: 6)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 38))
                    .foregroundColor(.white)
            }

            Text("RuView Sensing")
                .font(.title2).fontWeight(.bold).foregroundColor(.healthText)

            Text("Enter the IP or hostname (e.g. simha.local) of your Orange Pi sensing server to start monitoring.")
                .font(.callout).foregroundColor(.healthSub).multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Address")
                .font(.subheadline).fontWeight(.semibold).foregroundColor(.healthSub)

            HStack {
                Image(systemName: "network").foregroundColor(.steel).frame(width: 20)

                TextField("192.168.1.100", text: $inputHost)
                    .textFieldStyle(.plain)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit { attemptConnect() }
                    .foregroundColor(.healthText)

                if !inputHost.isEmpty {
                    Button {
                        inputHost = ""
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.healthSub)
                    }
                }
            }
            .padding(14)
            .background(Color.surface)
            .cornerRadius(12)
            .shadow(color: Color.steel.opacity(0.10), radius: 6, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(errorMessage != nil ? Color.red.opacity(0.45) : Color.steelLight.opacity(0.50), lineWidth: 1.5)
            )

            Text("Ports 3022 (REST) and 3023 (WebSocket) will be used")
                .font(.caption).foregroundColor(.healthSub)
        }
    }

    // MARK: - Connect button

    private var connectButton: some View {
        Button(action: attemptConnect) {
            HStack {
                if isChecking {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "checkmark.circle").foregroundColor(.white)
                }
                Text(isChecking ? "Checking connection…" : "Connect")
                    .fontWeight(.semibold).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                Group {
                    if inputHost.trimmingCharacters(in: .whitespaces).isEmpty || isChecking {
                        AnyView(Color.steel.opacity(0.40))
                    } else {
                        AnyView(SteelGradient.horizontal)
                    }
                }
            )
            .cornerRadius(14)
            .shadow(color: Color.steel.opacity(0.30), radius: 8, x: 0, y: 4)
        }
        .disabled(inputHost.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
        .animation(.easeInOut(duration: 0.2), value: isChecking)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            Text(message).font(.callout).foregroundColor(.red)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.20), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Help section

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("How to find the server address", systemImage: "questionmark.circle")
                .font(.subheadline).fontWeight(.semibold).foregroundColor(.healthText)

            helpRow(icon: "1.circle.fill", text: "Connect your iPhone to the same WiFi network as the Orange Pi.")
            helpRow(icon: "2.circle.fill", text: "On the Orange Pi, run: ip addr show | grep 'inet '")
            helpRow(icon: "3.circle.fill", text: "Look for an address like 192.168.x.x and enter it above.")
        }
        .ruCard()
    }

    private func helpRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(.steel).frame(width: 22, height: 22)
            Text(text).font(.callout).foregroundColor(.healthSub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Logic

    private func attemptConnect() {
        let trimmed = inputHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard isValidHost(trimmed) else {
            withAnimation {
                errorMessage = "Please enter an IP (e.g. 192.168.1.100) or hostname (e.g. simha.local)"
            }
            return
        }

        isChecking = true
        errorMessage = nil

        Task {
            do {
                guard let url = URL(string: "http://\(trimmed):3022/health") else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                _ = try? JSONDecoder().decode(HealthResponse.self, from: data)

                await MainActor.run {
                    isChecking = false
                    deviceHost = trimmed
                    onConnected(trimmed)
                }
            } catch let urlError as URLError {
                await MainActor.run {
                    isChecking = false
                    switch urlError.code {
                    case .cannotConnectToHost, .networkConnectionLost:
                        errorMessage = "Cannot reach server at \(trimmed):3022. Check the address and ensure the server is running."
                    case .timedOut:
                        errorMessage = "Connection timed out. The server may be busy or unreachable."
                    case .notConnectedToInternet:
                        errorMessage = "No internet connection. Connect to the same network as the server."
                    default:
                        errorMessage = "Could not connect to server. Verify the address and try again."
                    }
                }
            } catch {
                await MainActor.run {
                    isChecking = false
                    errorMessage = "Connection failed. Verify the server is running and try again."
                }
            }
        }
    }

    /// Accept either an IPv4 dotted-quad ("192.168.8.11") or a hostname
    /// ("simha.local", "orangepi.local", "ruview-server"). The latter resolves
    /// via the device's DNS / mDNS resolver — particularly useful when the
    /// Pi's IP changes between networks (phone hotspot vs. home WiFi).
    private func isValidHost(_ string: String) -> Bool {
        let parts = string.split(separator: ".").map(String.init)
        if parts.count == 4 && parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return true   // IPv4
        }
        return !string.isEmpty && !string.contains(" ") && !string.hasPrefix(".") && !string.hasSuffix(".")
    }
}
