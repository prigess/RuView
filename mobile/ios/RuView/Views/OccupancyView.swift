import SwiftUI

// MARK: - OccupancyView

struct OccupancyView: View {
    @ObservedObject var viewModel: SensingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Current Status",
                              trailing: (viewModel.isLiveDataFlowing || viewModel.radarCountIsLive) ? "Live · Updated just now" : "Waiting for data")
                personCountCard
                ld2450TrackingSection
                soundCard
                stateSummaryCard
                presenceTimelineStrip
                SectionHeader(title: "Details")
                classificationDetails
                SectionHeader(title: "Source")
                sourceCard
            }
            .padding(16)
        }
        .background(Color.steelPale.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Occupancy")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await viewModel.refreshNodes()
            await viewModel.refreshZones()
            await viewModel.refreshAdaptiveStatus()
        }
    }

    // MARK: - Person count

    private var personCountCard: some View {
        ZStack {
            SteelGradient.main
                .cornerRadius(20)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    let live = viewModel.isLiveDataFlowing || viewModel.radarCountIsLive
                    LivePulseDot(color: .white, size: 7, active: live)
                    Text(live ? "LIVE" : "WAITING")
                        .font(.caption2).fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.85))
                        .tracking(1.5)
                }

                // Live occupant count from the LD2450 radar (true multi-target
                // count; 0 whenever the room is empty). Falls back to the
                // server count when the radar is offline.
                Text("\(occupantCount)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 220)

                Text(occupancySubtitle)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.85))

                // Inline vitals only when someone is here AND a vitals sensor is
                // actually reporting — with no C6 attached we hide the row rather
                // than show a broken "—/—".
                if occupantCount > 0,
                   viewModel.fusedHeartRate != nil || viewModel.fusedBreathingRate != nil {
                    HStack(spacing: 22) {
                        vitalChip(icon: "heart.fill",
                                  value: viewModel.fusedHeartRate.map { "\($0)" } ?? "—",
                                  unit: "bpm")
                        Rectangle().fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 22)
                        vitalChip(icon: "lungs.fill",
                                  value: viewModel.fusedBreathingRate.map { "\($0)" } ?? "—",
                                  unit: "bpm")
                    }
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 8)
            .animation(.easeOut(duration: 0.18), value: occupantCount)
        }
        .shadow(color: Color.steel.opacity(0.40), radius: 14, x: 0, y: 7)
    }

    /// Live occupant count for the hero (radar-first, 0 when empty).
    private var occupantCount: Int { viewModel.radarOccupantCount }

    private var occupancySubtitle: String {
        switch occupantCount {
        case 0:  return "Room is empty"
        case 1:  return "1 person in the room"
        default: return "\(occupantCount) people in the room"
        }
    }

    private func vitalChip(icon: String, value: String, unit: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(.white.opacity(0.85))
            Text(value).font(.title3).fontWeight(.semibold).foregroundColor(.white)
                .monospacedDigit()
            Text(unit).font(.caption).foregroundColor(.white.opacity(0.7))
        }
    }

    // MARK: - LD2450 live tracking (direct radar poll)
    //
    // Only rendered when the LD2450 node is reachable. Shows a live person
    // count and a top-down plot of each tracked target's (x, y) position —
    // the multi-target capability the CSI/C6 nodes can't give us.
    @ViewBuilder
    private var ld2450TrackingSection: some View {
        if viewModel.ld2450Reachable, let reading = viewModel.ld2450Reading {
            SectionHeader(title: "Live Tracking", trailing: "LD2450 radar")
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    // Show the FUSED count (same as the hero) so the two never
                    // contradict. The raw radar returns live in the plot below.
                    let shown = viewModel.radarOccupantCount
                    if shown > 0 {
                        Text("\(shown)")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundColor(.healthText)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shown == 1 ? "person tracked" : "people tracked")
                                .font(.callout).foregroundColor(.healthSub)
                            Text("\(reading.movingCount) moving")
                                .font(.caption).foregroundColor(.healthSub.opacity(0.7))
                        }
                    } else {
                        Text("0")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundColor(.healthSub)
                        Text("no one tracked")
                            .font(.callout).foregroundColor(.healthSub)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        LivePulseDot(color: .steel, size: 7, active: true)
                        Text("LIVE").font(.caption2).fontWeight(.bold)
                            .foregroundColor(.steel).tracking(1.5)
                    }
                }
                LD2450RadarPlot(targets: reading.targets)
                    .frame(height: 230)
                if !viewModel.ld2450AntennaConnected {
                    // Antenna off: the plot may show ghost returns. Be explicit
                    // that the trusted count comes from the presence sensors.
                    Text("Raw radar returns — LD2450 antenna not attached, so extra dots may be ghosts. Count above is from the presence sensors.")
                        .font(.caption).foregroundColor(.healthSub.opacity(0.7))
                        .multilineTextAlignment(.center)
                } else if reading.targets.isEmpty {
                    Text(viewModel.anyPresenceEvidence
                         ? "Detected by presence sensor — outside the radar's localization range"
                         : "No targets in radar view")
                        .font(.caption).foregroundColor(.healthSub.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            .ruCard()
            .animation(.easeOut(duration: 0.25), value: viewModel.radarOccupantCount)
        }
    }

    // MARK: - Sound (INMP441 mic — loudness only, interim before voice sentiment)

    @ViewBuilder
    private var soundCard: some View {
        if viewModel.micReachable {
            SectionHeader(title: "Sound", trailing: "INMP441 mic")
            HStack(spacing: 14) {
                Image(systemName: viewModel.impactDetected
                      ? "waveform.badge.exclamationmark"
                      : (viewModel.soundActive ? "waveform" : "waveform.slash"))
                    .font(.system(size: 30))
                    .foregroundColor(viewModel.impactDetected ? .red
                                     : (viewModel.soundActive ? .steel : .healthSub))
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.impactDetected ? "Loud event detected"
                         : (viewModel.soundActive ? "Sound activity" : "Quiet"))
                        .font(.callout).fontWeight(.semibold)
                        .foregroundColor(viewModel.impactDetected ? .red : .healthText)
                    Text(viewModel.soundLevelDb.map { String(format: "%.0f dB", $0) } ?? "—")
                        .font(.caption).foregroundColor(.healthSub).monospacedDigit()
                }
                Spacer()
                SoundLevelBar(db: viewModel.soundLevelDb, active: viewModel.soundActive)
            }
            .ruCard()
            .animation(.easeOut(duration: 0.2), value: viewModel.impactDetected)
            .animation(.easeOut(duration: 0.2), value: viewModel.soundActive)
        }
    }

    // MARK: - State summary (replaces the old "Confidence %" card)

    /// Time-in-state + last-seen + motion description. Replaces the old
    /// "Confidence 85%" pill which didn't answer the caregiver's actual
    /// question. Layout: motion chip on top, then big time-in-state,
    /// then last-seen if applicable.
    private var stateSummaryCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(viewModel.motionColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Circle()
                        .fill(viewModel.motionColor)
                        .frame(width: 14, height: 14)
                }
                Text(viewModel.displayPresence
                     ? viewModel.stickyMotionLevelDisplay
                     : "Quiet")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundColor(.healthText)
            }

            Text(viewModel.timeInStateLabel)
                .font(.callout)
                .foregroundColor(.healthSub)
                .monospacedDigit()

            if let lastSeen = viewModel.lastSeenLabel {
                Text(lastSeen)
                    .font(.caption)
                    .foregroundColor(.healthSub.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .ruCard()
    }

    // MARK: - 24h presence timeline strip
    //
    // Horizontal band: shaded blocks when the room was Present, blank when
    // Empty. Pure read-at-a-glance — answers "what's the pattern today?"
    private var presenceTimelineStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 24 h")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(.healthSub)
                Spacer()
                Text(presenceTimeRangeLabel())
                    .font(.caption2).foregroundColor(.healthSub.opacity(0.7))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.steel.opacity(0.10))

                    // Presence bands
                    ForEach(timelineBands(width: geo.size.width), id: \.id) { band in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.steel)
                            .frame(width: max(2, band.width), height: 16)
                            .offset(x: band.x, y: 0)
                    }

                    // "now" marker (right edge)
                    Rectangle()
                        .fill(Color.healthText.opacity(0.6))
                        .frame(width: 2, height: 22)
                        .offset(x: geo.size.width - 1, y: -3)
                }
            }
            .frame(height: 22)
            HStack {
                Text("24 h ago").font(.caption2).foregroundColor(.healthSub.opacity(0.7))
                Spacer()
                Text("now").font(.caption2).foregroundColor(.healthSub.opacity(0.7))
            }
        }
        .padding(14)
        .ruCard()
    }

    /// Returns positioned bands (x, width) representing past Present spans.
    private struct Band: Identifiable { let id = UUID(); let x: CGFloat; let width: CGFloat }
    private func timelineBands(width: CGFloat) -> [Band] {
        let now = Date()
        let windowSec: TimeInterval = 24 * 3600
        let start = now.addingTimeInterval(-windowSec)
        // Pair samples into spans (s_at → next.at), keeping spans where present == true.
        var spans: [(Date, Date)] = []
        let samples = viewModel.presenceHistory.filter { $0.at >= start }
        if samples.isEmpty { return [] }
        for i in 0..<samples.count {
            let s = samples[i]
            guard s.present else { continue }
            let endAt: Date = (i + 1 < samples.count) ? samples[i + 1].at : now
            spans.append((max(s.at, start), endAt))
        }
        return spans.map { (s, e) in
            let xFrac = CGFloat(s.timeIntervalSince(start) / windowSec)
            let wFrac = CGFloat(e.timeIntervalSince(s) / windowSec)
            return Band(x: xFrac * width, width: max(2, wFrac * width))
        }
    }

    private func presenceTimeRangeLabel() -> String {
        let now = Date()
        let start = now.addingTimeInterval(-24 * 3600)
        let f = DateFormatter(); f.dateFormat = "h a"
        return "\(f.string(from: start))  →  \(f.string(from: now))"
    }

    // MARK: - Motion badge (deprecated — kept for back-compat, no longer rendered)
    private var motionBadgeCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(viewModel.motionColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Circle()
                        .fill(viewModel.motionColor)
                        .frame(width: 14, height: 14)
                }
                Text(viewModel.motionLevelDisplay)
                    .font(.title2).fontWeight(.semibold)
                    .foregroundColor(.healthText)
            }

            Text("Confidence: \(String(format: "%.0f%%", viewModel.overallConfidence * 100))")
                .font(.callout).foregroundColor(.healthSub)
                .monospacedDigit()

            confidenceBar(value: viewModel.overallConfidence)
        }
        .frame(maxWidth: .infinity)
        .ruCard()
    }

    // MARK: - Classification details

    private var classificationDetails: some View {
        VStack(spacing: 0) {
            // Use the sticky displayPresence (10s hysteresis) so the
            // detail row matches the hero. Reading raw classification.presence
            // here would flap at 10 Hz alongside the classifier oscillation.
            detailRow(label: "Presence",
                      value: viewModel.displayPresence ? "Detected" : "Not detected",
                      icon: "person.fill")
            Divider().padding(.leading, 52)
            // While the room is held "Present", suppress brief "absent"
            // motion blips so the row doesn't flap between Active and Absent.
            detailRow(label: "Motion level",
                      value: viewModel.stickyMotionLevelDisplay,
                      icon: "waveform")
            Divider().padding(.leading, 52)
            signalHealthRow(health: viewModel.signalHealth)
            Divider().padding(.leading, 52)
            detailRow(label: "Active nodes",
                      value: "\(viewModel.snapshot?.nodeFeatures?.count ?? 0)",
                      icon: "antenna.radiowaves.left.and.right")
        }
        .background(Color.surface)
        .cornerRadius(16)
        .shadow(color: Color.steel.opacity(0.10), radius: 8, x: 0, y: 3)
    }

    private func detailRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.steel)
                .frame(width: 28, height: 28)
                .background(Color.steel.opacity(0.10))
                .cornerRadius(6)
            Text(label).foregroundColor(.healthSub)
            Spacer()
            Text(value).fontWeight(.medium).foregroundColor(.healthText)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    /// Stoplight (green / yellow / red) version of the old "Last tick" row.
    /// Replaces a developer-facing counter with a caregiver-readable status
    /// pill so the user instantly knows whether to trust what they see.
    private func signalHealthRow(health: SensingViewModel.SignalHealth) -> some View {
        let tint: Color = {
            switch health {
            case .green:  return Color(red: 0.16, green: 0.65, blue: 0.42) // healthcare green
            case .yellow: return Color(red: 0.96, green: 0.64, blue: 0.38) // soft amber
            case .red:    return Color(red: 0.90, green: 0.44, blue: 0.32) // muted coral
            }
        }()

        return HStack(spacing: 12) {
            // Solid coloured dot — universal traffic-light cue
            Circle()
                .fill(tint)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().stroke(tint.opacity(0.35), lineWidth: 4)
                        .scaleEffect(1.6)
                        .opacity(health == .green ? 0.6 : 0)   // gentle pulse only on green
                )
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Data status").foregroundColor(.healthSub).font(.subheadline)
                Text(health.subtitle).font(.caption).foregroundColor(.healthSub.opacity(0.7))
            }
            Spacer()

            // Status pill on the right
            HStack(spacing: 6) {
                Image(systemName: health.systemImage)
                Text(health.label)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundColor(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.15))
            .cornerRadius(999)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: - Source card

    private var sourceCard: some View {
        HStack(spacing: 12) {
            LivePulseDot(
                color: viewModel.isDemoMode ? .orange : .steel,
                size: 9,
                active: viewModel.isLiveDataFlowing
            )
            Text(viewModel.isDemoMode ? "Demo Mode — simulated data" : "Live — ESP32 sensor data")
                .font(.callout).foregroundColor(.healthSub)
            Spacer()
            Text(viewModel.sourceLabel)
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(viewModel.isDemoMode ? Color.orange.opacity(0.12) : Color.steel.opacity(0.12))
                .foregroundColor(viewModel.isDemoMode ? .orange : .steel)
                .cornerRadius(6)
        }
        .ruCard()
    }

    // MARK: - Confidence bar

    private func confidenceBar(value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.steelLight.opacity(0.35))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SteelGradient.horizontal)
                    .frame(width: geo.size.width * CGFloat(value), height: 8)
                    .animation(.easeInOut(duration: 0.4), value: value)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - LD2450 top-down radar plot

/// Bird's-eye view of the LD2450's field: the sensor sits at bottom-center
/// looking "up" the view. X maps left↔right, Y maps near↔far. Each active
/// target is a labelled dot with its straight-line distance.
/// Compact live sound-level meter. Maps Leq (-60…-10 dBFS) to a 0…1 fill.
private struct SoundLevelBar: View {
    let db: Double?
    let active: Bool
    var body: some View {
        let level = db.map { max(0.0, min(1.0, ($0 + 60.0) / 50.0)) } ?? 0.0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.steel.opacity(0.15))
                Capsule().fill(active ? Color.steel : Color.healthSub)
                    .frame(width: max(4, geo.size.width * level))
            }
        }
        .frame(width: 96, height: 8)
    }
}

private struct LD2450RadarPlot: View {
    let targets: [LD2450Target]

    private let maxX: Double = 2500   // mm shown to each side
    private let maxY: Double = 4000   // mm of depth shown
    private let topPad: CGFloat = 16
    private let bottomPad: CGFloat = 40   // reserve room for the sensor marker

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.steel.opacity(0.06))
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.steel.opacity(0.15), lineWidth: 1)

                // Depth gridlines (~every 1.25 m).
                ForEach(1..<4) { i in
                    let yy = h * CGFloat(i) / 4.0
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: yy))
                        p.addLine(to: CGPoint(x: w, y: yy))
                    }
                    .stroke(Color.steel.opacity(0.10), lineWidth: 1)
                }
                // Center boresight line.
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0))
                    p.addLine(to: CGPoint(x: w / 2, y: h))
                }
                .stroke(Color.steel.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

                // Sensor marker at bottom-center.
                VStack(spacing: 2) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.steel)
                    Text("radar").font(.system(size: 8)).foregroundColor(.healthSub.opacity(0.7))
                }
                .position(x: w / 2, y: h - 12)

                // Active targets.
                ForEach(targets) { t in
                    let cx = min(max(t.x, -maxX), maxX)
                    let cy = min(max(t.y, 0), maxY)
                    let px = w / 2 + CGFloat(cx / maxX) * (w / 2 - 22)
                    // Near targets sit just above the sensor marker (not jammed
                    // at the very bottom); far targets rise toward the top.
                    let py = (h - bottomPad) - CGFloat(cy / maxY) * (h - bottomPad - topPad)
                    ZStack {
                        Circle().fill(Color.steel.opacity(0.20)).frame(width: 38, height: 38)
                        Circle().fill(Color.steel).frame(width: 20, height: 20)
                        Text("\(t.id)").font(.caption2).fontWeight(.bold).foregroundColor(.white)
                    }
                    .position(x: px, y: py)
                    Text(String(format: "%.1f m", t.distanceMeters))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.healthSub)
                        .position(x: px, y: py - 24)
                }
            }
        }
    }
}
