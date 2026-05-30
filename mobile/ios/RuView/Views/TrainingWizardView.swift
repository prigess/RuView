import SwiftUI

// MARK: - TrainingWizardView

struct TrainingWizardView: View {
    @ObservedObject var viewModel: SensingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep: Int = 0
    @State private var calibrationStatus: CalibrationStatus?
    @State private var calibrationPollTask: Task<Void, Never>?
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var trainResult: BoolResponse?
    @State private var groundTruthCount: Int = 1
    @State private var groundTruthResult: BoolResponse?
    @State private var currentRecordingLabel: String = ""
    @State private var recordingCountdown: Int = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var completedLabels: [String] = []

    private let recordingLabels = ["absent", "present_still", "present_moving", "active"]
    private let recordingDuration = 30 // seconds per label

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                progressIndicator
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 20) {
                        stepView
                    }
                    .padding(20)
                }

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .padding(.top, 8)
            }
            .navigationTitle("Training Wizard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        cleanup()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Progress indicator

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { step in
                Capsule()
                    .fill(step <= currentStep ? Color.blue : Color(.systemGray4))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.3), value: currentStep)
            }
        }
    }

    // MARK: - Step router

    @ViewBuilder
    private var stepView: some View {
        switch currentStep {
        case 0: step0Welcome
        case 1: step1Calibration
        case 2: step2Recording
        case 3: step3Training
        case 4: step4GroundTruth
        case 5: step5Done
        default: EmptyView()
        }
    }

    // MARK: - Step 0: Welcome

    private var step0Welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "graduationcap.fill",
                iconColor: .blue,
                title: "Train Your Classifier",
                subtitle: "This wizard guides you through calibrating and training the adaptive sensing classifier for your environment."
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Prerequisites")
                    .font(.headline)

                checkRow(text: "Sensing server is running and connected", checked: viewModel.isConnected)
                checkRow(text: "All ESP32 nodes are powered on", checked: viewModel.nodes.count > 0)
                checkRow(text: "Room is clear for calibration step", checked: true)
                checkRow(text: "You have 5–10 minutes available", checked: true)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Steps overview")
                    .font(.headline)

                overviewRow(number: "1", title: "Calibrate", description: "Establish baseline signal")
                overviewRow(number: "2", title: "Record", description: "Record 4 activity labels")
                overviewRow(number: "3", title: "Train", description: "Train the classifier")
                overviewRow(number: "4", title: "Ground truth", description: "Set expected person count")
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            if !viewModel.isConnected {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Connect to a sensing server before proceeding.")
                        .font(.callout)
                        .foregroundColor(.orange)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }

    // MARK: - Step 1: Calibration

    private var step1Calibration: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "waveform.path.ecg",
                iconColor: .purple,
                title: "Baseline Calibration",
                subtitle: "The system captures the baseline WiFi signal with the room empty. Please leave the sensing area now."
            )

            if let status = calibrationStatus {
                calibrationProgressCard(status: status)
            } else {
                startCalibrationCard
            }

            if let error = errorMessage {
                errorBanner(message: error)
            }
        }
    }

    private var startCalibrationCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundColor(.purple)

            Text("Ready to calibrate")
                .font(.headline)

            Text("Make sure the sensing area is empty, then tap Start Calibration.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: beginCalibration) {
                actionButtonLabel(title: "Start Calibration", isLoading: isWorking)
            }
            .disabled(isWorking)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func calibrationProgressCard(status: CalibrationStatus) -> some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calibrating…")
                        .font(.headline)
                    Text(status.status.capitalized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if status.active {
                    ProgressView()
                }
            }

            if let frames = status.frames, let target = status.target, target > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: Double(frames), total: Double(target))
                        .tint(.purple)
                    Text("\(frames) / \(target) frames")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if status.active {
                Button(action: stopCalibrationAction) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Calibration")
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(10)
                }
                .disabled(isWorking)
            } else {
                // Calibration finished
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Calibration complete")
                        .foregroundColor(.green)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Step 2: Recording

    private var step2Recording: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "record.circle",
                iconColor: .red,
                title: "Record Activities",
                subtitle: "Record each activity label in sequence. Follow the instructions for each label."
            )

            ForEach(Array(recordingLabels.enumerated()), id: \.element) { index, label in
                recordingLabelCard(label: label, index: index)
            }

            if let error = errorMessage {
                errorBanner(message: error)
            }
        }
    }

    private func recordingLabelCard(label: String, index: Int) -> some View {
        let isCompleted = completedLabels.contains(label)
        let isActive = currentRecordingLabel == label

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Status icon
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if isActive {
                    Image(systemName: "record.circle.fill")
                        .foregroundColor(.red)
                } else {
                    Text("\(index + 1)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(.systemGray3))
                        .clipShape(Circle())
                }

                Text(label.motionLevelDisplay)
                    .font(.headline)

                Spacer()

                if isActive && recordingCountdown > 0 {
                    Text("\(recordingCountdown)s")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                        .monospacedDigit()
                }
            }

            Text(recordingInstruction(for: label))
                .font(.callout)
                .foregroundColor(.secondary)

            if isActive {
                if recordingCountdown > 0 {
                    ProgressView(
                        value: Double(recordingDuration - recordingCountdown),
                        total: Double(recordingDuration)
                    )
                    .tint(.red)
                } else {
                    Button(action: { startRecordingLabel(label) }) {
                        actionButtonLabel(title: "Start Recording \"\(label.motionLevelDisplay)\"", isLoading: isWorking)
                    }
                    .disabled(isWorking)
                }
            } else if !isCompleted && completedLabels.count == index {
                // This is the next label to record
                Button(action: { startRecordingLabel(label) }) {
                    actionButtonLabel(title: "Record \"\(label.motionLevelDisplay)\"", isLoading: false)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Color.red.opacity(0.05) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
    }

    private func recordingInstruction(for label: String) -> String {
        switch label {
        case "absent": return "Leave the sensing area completely. No people should be present."
        case "present_still": return "Stand still in the sensing area. Do not move."
        case "present_moving": return "Walk slowly around the sensing area at a normal pace."
        case "active": return "Move actively: wave your arms, move quickly, simulate high activity."
        default: return "Perform the labeled activity in the sensing area."
        }
    }

    // MARK: - Step 3: Training

    private var step3Training: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "brain.head.profile",
                iconColor: .indigo,
                title: "Train Classifier",
                subtitle: "The system trains an adaptive classifier using your recorded data."
            )

            if let result = trainResult {
                trainingResultCard(result: result)
            } else {
                trainReadyCard
            }

            if let error = errorMessage {
                errorBanner(message: error)
            }
        }
    }

    private var trainReadyCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundColor(.indigo)

            Text("Ready to train")
                .font(.headline)

            Text("Training uses the \(completedLabels.count) recorded labels. This may take 30–60 seconds.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: runTraining) {
                actionButtonLabel(title: "Train Classifier", isLoading: isWorking)
            }
            .disabled(isWorking)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func trainingResultCard(result: BoolResponse) -> some View {
        VStack(spacing: 12) {
            if result.success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)

                Text("Training complete!")
                    .font(.headline)
                    .foregroundColor(.green)

                if let accuracy = result.accuracy {
                    VStack(spacing: 4) {
                        Text("\(String(format: "%.1f%%", accuracy * 100))")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Classifier accuracy")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.red)

                Text("Training failed")
                    .font(.headline)
                    .foregroundColor(.red)

                if let err = result.error {
                    Text(err)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: runTraining) {
                    actionButtonLabel(title: "Retry Training", isLoading: isWorking)
                }
                .disabled(isWorking)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Step 4: Ground truth

    private var step4GroundTruth: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "person.3.fill",
                iconColor: .orange,
                title: "Set Ground Truth",
                subtitle: "Tell the system how many people are currently in the sensing area to calibrate person counting."
            )

            VStack(spacing: 16) {
                Text("How many people are in the room right now?")
                    .font(.callout)
                    .foregroundColor(.secondary)

                HStack {
                    Button {
                        if groundTruthCount > 0 { groundTruthCount -= 1 }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title)
                            .foregroundColor(.blue)
                    }

                    Text("\(groundTruthCount)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .frame(minWidth: 80)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3), value: groundTruthCount)

                    Button {
                        groundTruthCount += 1
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title)
                            .foregroundColor(.blue)
                    }
                }

                Button(action: applyGroundTruth) {
                    actionButtonLabel(title: "Apply Ground Truth", isLoading: isWorking)
                }
                .disabled(isWorking)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            if let result = groundTruthResult, result.success {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ground truth applied")
                            .fontWeight(.medium)
                        if let factor = result.computedDedupFactor {
                            Text("Dedup factor: \(String(format: "%.2f", factor))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.1))
                .cornerRadius(10)
            }

            if let error = errorMessage {
                errorBanner(message: error)
            }
        }
    }

    // MARK: - Step 5: Done

    private var step5Done: some View {
        VStack(spacing: 24) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Training Complete!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your classifier is trained and ready. The sensing system will now use your custom training data for improved accuracy.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                if let accuracy = trainResult?.accuracy {
                    summaryRow(label: "Classifier accuracy", value: "\(String(format: "%.1f%%", accuracy * 100))", color: .green)
                }
                summaryRow(label: "Labels recorded", value: "\(completedLabels.count)", color: .blue)
                if let factor = groundTruthResult?.computedDedupFactor {
                    summaryRow(label: "Person dedup factor", value: String(format: "%.2f", factor), color: .orange)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if currentStep > 0 && currentStep < 5 {
                Button {
                    withAnimation { currentStep -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            if currentStep < 5 {
                nextButton
            }
        }
    }

    @ViewBuilder
    private var nextButton: some View {
        switch currentStep {
        case 0:
            Button {
                withAnimation { currentStep = 1 }
            } label: {
                primaryButton(title: "Begin")
            }
            .disabled(!viewModel.isConnected)

        case 1:
            let calDone = calibrationStatus != nil && calibrationStatus?.active == false
            Button {
                withAnimation { currentStep = 2 }
            } label: {
                primaryButton(title: "Next: Record")
            }
            .disabled(!calDone)

        case 2:
            Button {
                withAnimation { currentStep = 3 }
            } label: {
                primaryButton(title: "Next: Train")
            }
            .disabled(completedLabels.count < recordingLabels.count)

        case 3:
            Button {
                withAnimation { currentStep = 4 }
            } label: {
                primaryButton(title: "Next: Ground Truth")
            }
            .disabled(trainResult == nil || trainResult?.success == false)

        case 4:
            Button {
                withAnimation { currentStep = 5 }
            } label: {
                primaryButton(title: "Finish")
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func beginCalibration() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                _ = try await viewModel.client.startCalibration()
                await pollCalibrationStatus()
            } catch {
                errorMessage = "Failed to start calibration. Check connection and try again."
            }
            isWorking = false
        }
    }

    private func stopCalibrationAction() {
        isWorking = true
        Task {
            do {
                _ = try await viewModel.client.stopCalibration()
                calibrationStatus = try? await viewModel.client.fetchCalibrationStatus()
            } catch {
                errorMessage = "Failed to stop calibration."
            }
            isWorking = false
        }
    }

    private func pollCalibrationStatus() async {
        calibrationPollTask?.cancel()
        calibrationPollTask = Task {
            while !Task.isCancelled {
                if let status = try? await viewModel.client.fetchCalibrationStatus() {
                    await MainActor.run {
                        calibrationStatus = status
                    }
                    if !status.active { break }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        await calibrationPollTask?.value
    }

    private func startRecordingLabel(_ label: String) {
        guard !isWorking else { return }
        isWorking = true
        currentRecordingLabel = label
        errorMessage = nil

        Task {
            do {
                _ = try await viewModel.client.startRecording(name: label)
                await startCountdown()
                _ = try await viewModel.client.stopRecording()
                await MainActor.run {
                    completedLabels.append(label)
                    currentRecordingLabel = ""
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Recording failed for \"\(label)\". Check connection and try again."
                    currentRecordingLabel = ""
                    isWorking = false
                }
            }
        }
    }

    private func startCountdown() async {
        await MainActor.run { recordingCountdown = recordingDuration }
        for i in stride(from: recordingDuration, through: 0, by: -1) {
            await MainActor.run { recordingCountdown = i }
            if i > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func runTraining() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let result = try await viewModel.client.retrainClassifier()
                trainResult = result
                if !result.success {
                    errorMessage = result.error ?? "Training failed. Please try again."
                }
            } catch {
                errorMessage = "Could not complete training. Check connection and try again."
            }
            isWorking = false
        }
    }

    private func applyGroundTruth() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let result = try await viewModel.client.setGroundTruth(groundTruthCount)
                groundTruthResult = result
            } catch {
                errorMessage = "Failed to apply ground truth. Check connection and try again."
            }
            isWorking = false
        }
    }

    private func cleanup() {
        calibrationPollTask?.cancel()
        countdownTask?.cancel()
    }

    // MARK: - Reusable UI components

    private func stepHeader(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(iconColor)

            Text(title)
                .font(.title2)
                .fontWeight(.bold)

            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private func checkRow(text: String, checked: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundColor(checked ? .green : .secondary)
            Text(text)
                .font(.callout)
                .foregroundColor(checked ? .primary : .secondary)
        }
    }

    private func overviewRow(number: String, title: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.callout)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func actionButtonLabel(title: String, isLoading: Bool) -> some View {
        HStack {
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.85)
            }
            Text(isLoading ? "Working…" : title)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.blue)
        .foregroundColor(.white)
        .cornerRadius(10)
    }

    private func primaryButton(title: String) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
    }

    private func summaryRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.callout)
                .foregroundColor(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
    }
}
