import SwiftUI

// MARK: - DeviceSetupView

struct DeviceSetupView: View {
    @AppStorage("deviceHost") private var deviceHost: String = ""
    @State private var inputHost: String = ""
    @State private var isChecking: Bool = false
    @State private var errorMessage: String?
    @State private var showSuccess: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    let onConnected: (String) -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
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
            .navigationTitle("Connect to RuView")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            inputHost = deviceHost.isEmpty ? "" : deviceHost
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("RuView Sensing")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the IP address of your Orange Pi sensing server to start monitoring WiFi-based pose estimation.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Address")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack {
                Image(systemName: "network")
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                TextField("192.168.1.100", text: $inputHost)
                    .textFieldStyle(.plain)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit { attemptConnect() }

                if !inputHost.isEmpty {
                    Button {
                        inputHost = ""
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(errorMessage != nil ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1)
            )

            Text("Ports 3022 (REST) and 3023 (WebSocket) will be used")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var connectButton: some View {
        Button(action: attemptConnect) {
            HStack {
                if isChecking {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "checkmark.circle")
                }
                Text(isChecking ? "Checking connection…" : "Connect")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(buttonBackground)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(inputHost.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
        .animation(.easeInOut(duration: 0.2), value: isChecking)
    }

    private var buttonBackground: Color {
        let trimmed = inputHost.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty || isChecking) ? .blue.opacity(0.4) : .blue
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.callout)
                .foregroundColor(.red)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How to find the server address")
                .font(.subheadline)
                .fontWeight(.medium)

            helpRow(icon: "1.circle.fill", text: "Connect your iPhone to the same WiFi network as the Orange Pi.")
            helpRow(icon: "2.circle.fill", text: "On the Orange Pi, run: ip addr show | grep 'inet '")
            helpRow(icon: "3.circle.fill", text: "Look for an address like 192.168.x.x and enter it above.")
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func helpRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 22, height: 22)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Logic

    private func attemptConnect() {
        let trimmed = inputHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard isValidIP(trimmed) else {
            withAnimation {
                errorMessage = "Please enter a valid IP address (e.g. 192.168.1.100)"
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
                // Optionally parse status
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
                        errorMessage = "Cannot reach server at \(trimmed):3022. Check the IP and ensure the server is running."
                    case .timedOut:
                        errorMessage = "Connection timed out. The server may be busy or unreachable."
                    case .notConnectedToInternet:
                        errorMessage = "No internet connection. Connect to the same network as the server."
                    default:
                        errorMessage = "Could not connect to server. Verify the IP address and try again."
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

    private func isValidIP(_ string: String) -> Bool {
        let parts = string.split(separator: ".").map(String.init)
        // Accept hostname-like or standard IPv4
        if parts.count == 4 {
            return parts.allSatisfy { part in
                guard let value = Int(part), (0...255).contains(value) else { return false }
                return true
            }
        }
        // Allow plain hostnames
        return string.count > 0 && !string.contains(" ")
    }
}
