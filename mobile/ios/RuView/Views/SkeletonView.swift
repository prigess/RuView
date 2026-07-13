import SwiftUI

// MARK: - SkeletonView

struct SkeletonView: View {
    @ObservedObject var viewModel: SensingViewModel

    private let canvasWidth: CGFloat = 640
    private let canvasHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            statsBar
            skeletonCanvas.padding(16)
            personList
        }
        .background(Color.steelPale.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .navigationTitle("Skeleton")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Stats bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            statItem(label: "Persons", value: "\(personsShown)")
            Divider().frame(height: 32)
            statItem(label: "Motion", value: radarOccupied ? (isMoving ? "Moving" : "Still") : "—")
            Divider().frame(height: 32)
            statItem(label: "Source", value: radarOccupied && serverPersons.isEmpty ? "LD2450" : viewModel.sourceLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.surface)
        .shadow(color: Color.steel.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    // MARK: - Fused live state (radar-driven when the server pose feed is idle)

    private var serverPersons: [Person] { viewModel.snapshot?.persons ?? [] }

    /// Figures to draw from the LD2450. Falls back to a single centered figure
    /// when the count is positive but coordinates momentarily read zero (which
    /// happens at very close range) — so the skeleton never blinks out.
    private var radarFigures: [LD2450Target] {
        let targets = viewModel.ld2450Reachable ? (viewModel.ld2450Reading?.targets ?? []) : []
        if !targets.isEmpty { return targets }
        // Present per ANY radar (e.g. the LD2410C sees someone the LD2450 can't
        // localize) → a centered figure, so the skeleton matches the Occupancy
        // count instead of blinking out.
        if viewModel.radarOccupantCount > 0 {
            return [LD2450Target(id: 1, x: 0, y: 1200)]
        }
        return []
    }

    private var radarOccupied: Bool { !radarFigures.isEmpty }

    private var isMoving: Bool {
        (viewModel.ld2450Reading?.movingCount ?? 0) > 0
            || (viewModel.ld2410Reading?.movingPresent ?? false)
    }

    private var personsShown: Int {
        serverPersons.isEmpty ? viewModel.radarOccupantCount : serverPersons.count
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).fontWeight(.semibold).foregroundColor(.healthText)
            Text(label).font(.caption).foregroundColor(.healthSub)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Canvas

    private var skeletonCanvas: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / canvasWidth,
                geometry.size.height / canvasHeight
            )
            let scaledW = canvasWidth * scale
            let scaledH = canvasHeight * scale
            let offsetX = (geometry.size.width - scaledW) / 2
            let offsetY = (geometry.size.height - scaledH) / 2

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.07, green: 0.12, blue: 0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.steelDark.opacity(0.5), lineWidth: 1)
                    )

                if let persons = viewModel.snapshot?.persons, !persons.isEmpty {
                    Canvas { context, _ in
                        for (index, person) in persons.enumerated() {
                            drawPerson(
                                context: context, person: person,
                                scale: scale, offsetX: offsetX, offsetY: offsetY,
                                color: personColor(index: index)
                            )
                        }
                    }
                    ForEach(Array(persons.enumerated()), id: \.element.id) { index, person in
                        personLabel(person: person, index: index,
                                    scale: scale, offsetX: offsetX, offsetY: offsetY)
                    }
                } else if radarOccupied {
                    RadarSkeletonCanvas(
                        figures: radarFigures,
                        moving: isMoving,
                        drawRect: CGRect(x: offsetX, y: offsetY, width: scaledW, height: scaledH)
                    )
                } else {
                    emptySkeletonPlaceholder
                }
            }
        }
        .aspectRatio(canvasWidth / canvasHeight, contentMode: .fit)
        .shadow(color: Color.steelDark.opacity(0.30), radius: 12, x: 0, y: 6)
    }

    // MARK: - Draw person

    private func drawPerson(
        context: GraphicsContext,
        person: Person,
        scale: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat,
        color: Color
    ) {
        let keypointMap = Dictionary(uniqueKeysWithValues: person.keypoints.map { ($0.name, $0) })

        func point(for name: String) -> CGPoint? {
            guard let kp = keypointMap[name] else { return nil }
            return CGPoint(x: offsetX + CGFloat(kp.x) * scale,
                           y: offsetY + CGFloat(kp.y) * scale)
        }

        for (fromName, toName) in SkeletonEdge.edges {
            guard let fromPt = point(for: fromName),
                  let toPt = point(for: toName) else { continue }
            let fromKp = keypointMap[fromName]
            let toKp = keypointMap[toName]
            let avgConf = ((fromKp?.confidence ?? 0) + (toKp?.confidence ?? 0)) / 2
            let alpha = max(0.25, min(1.0, avgConf + 0.4))
            var path = Path()
            path.move(to: fromPt)
            path.addLine(to: toPt)
            context.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 2.5)
        }

        for keypoint in person.keypoints {
            let x = offsetX + CGFloat(keypoint.x) * scale
            let y = offsetY + CGFloat(keypoint.y) * scale
            let radius: CGFloat = keypoint.name == "nose" ? 5 : 4
            let alpha = max(0.3, min(1.0, keypoint.confidence + 0.35))
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            let circlePath = Path(ellipseIn: rect)
            context.fill(circlePath, with: .color(.white.opacity(alpha)))
            context.stroke(circlePath, with: .color(color.opacity(alpha)), lineWidth: 1.5)
        }
    }

    // MARK: - Person label

    private func personLabel(
        person: Person, index: Int,
        scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat
    ) -> some View {
        let anchor = person.keypoints.first(where: { $0.name == "nose" })
            ?? person.keypoints.first
        guard let anchor else { return AnyView(EmptyView()) }
        let x = offsetX + CGFloat(anchor.x) * scale
        let y = offsetY + CGFloat(anchor.y) * scale - 20

        return AnyView(
            VStack(spacing: 2) {
                Text("P\(index + 1)")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundColor(personColor(index: index))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.60)).cornerRadius(4)
                Text(person.pose.capitalized)
                    .font(.system(size: 8)).foregroundColor(.white.opacity(0.70))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.50)).cornerRadius(3)
            }
            .position(x: x, y: y)
        )
    }

    // MARK: - Empty state

    private var emptySkeletonPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.stand")
                .font(.system(size: 48))
                .foregroundColor(Color.steelLight.opacity(0.5))
            Text(viewModel.directDataLive ? "No persons detected" : "Not connected")
                .font(.callout).foregroundColor(Color.steelLight.opacity(0.85))
            if viewModel.directDataLive {
                HStack(spacing: 6) {
                    LivePulseDot(color: .steelLight, size: 6, active: viewModel.isLiveDataFlowing)
                    Text("Scanning room…")
                        .font(.caption2)
                        .foregroundColor(Color.steelLight.opacity(0.7))
                        .tracking(0.5)
                }
            }
        }
    }

    // MARK: - Person list

    private var personList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let persons = viewModel.snapshot?.persons, !persons.isEmpty {
                Text("Detected persons")
                    .font(.subheadline).fontWeight(.medium).foregroundColor(.healthSub)
                    .padding(.horizontal, 16).padding(.vertical, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(persons.enumerated()), id: \.element.id) { index, person in
                            personChip(person: person, index: index)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        }
    }

    private func personChip(person: Person, index: Int) -> some View {
        let color = personColor(index: index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("Person \(index + 1)")
                    .font(.caption).fontWeight(.semibold).foregroundColor(.healthText)
            }
            Text(person.pose.capitalized).font(.caption2).foregroundColor(.healthSub)
            Text("Conf: \(String(format: "%.0f%%", person.confidence * 100))")
                .font(.caption2).foregroundColor(.healthSub)
        }
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Colors

    private var personPalette: [Color] {
        [Color.steel, .orange, .green, .purple, .pink, Color.lungTeal, .indigo, .yellow]
    }

    private func personColor(index: Int) -> Color {
        personPalette[index % personPalette.count]
    }
}

// MARK: - RadarSkeletonCanvas
//
// A live stick figure per LD2450 target, positioned by its (x, y): x maps
// left↔right across the canvas, y maps near (bottom, larger) → far (top,
// smaller). When the person is moving the limbs swing in a walk cycle; when
// still the figure holds with a gentle idle sway. Driven by TimelineView's
// animation clock so it updates every frame regardless of data cadence.

private struct RadarSkeletonCanvas: View {
    let figures: [LD2450Target]
    let moving: Bool
    let drawRect: CGRect

    private let palette: [Color] = [.steel, .orange, Color.lungTeal]
    private let maxX: Double = 2500   // mm mapped to each side
    private let maxY: Double = 4000   // mm depth

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                for (i, fig) in figures.enumerated() {
                    drawFigure(&ctx, fig: fig, phase: phase,
                               color: palette[i % palette.count],
                               // stagger each figure's gait so two people
                               // don't march in lockstep
                               phaseOffset: Double(i) * 1.3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawFigure(_ ctx: inout GraphicsContext, fig: LD2450Target,
                            phase: Double, color: Color, phaseOffset: Double) {
        let r = drawRect
        let nx = max(-1.0, min(1.0, fig.x / maxX))
        let ny = max(0.0, min(1.0, fig.y / maxY))               // 0 near, 1 far
        let cx = r.midX + CGFloat(nx) * r.width * 0.38
        let H = r.height * CGFloat(0.60 - 0.26 * ny)            // near taller
        let feetY = r.maxY - r.height * 0.06 - CGFloat(ny) * r.height * 0.40

        let freq = moving ? 5.5 : 1.4
        let ph = (phase * freq) + phaseOffset
        let s = CGFloat(sin(ph))

        let legLen = H * 0.46
        let torso  = H * 0.32
        let headR  = H * 0.085
        let armLen = torso * 0.95
        let stepX  = moving ? H * 0.14 : H * 0.02
        let bob    = moving ? abs(CGFloat(sin(ph))) * H * 0.02 : 0

        let feet = feetY - bob
        let hipY = feet - legLen
        let neckY = hipY - torso
        let headCY = neckY - headR * 1.35
        let hip  = CGPoint(x: cx, y: hipY)
        let neck = CGPoint(x: cx, y: neckY)

        let lFoot = CGPoint(x: cx + s * stepX,
                            y: feet - (moving ? max(0, s) * H * 0.05 : 0))
        let rFoot = CGPoint(x: cx - s * stepX,
                            y: feet - (moving ? max(0, -s) * H * 0.05 : 0))
        let lKnee = CGPoint(x: (hip.x + lFoot.x) / 2 + H * 0.03, y: (hip.y + lFoot.y) / 2)
        let rKnee = CGPoint(x: (hip.x + rFoot.x) / 2 + H * 0.03, y: (hip.y + rFoot.y) / 2)

        let lHand = CGPoint(x: cx - s * stepX * 0.9, y: neckY + armLen)
        let rHand = CGPoint(x: cx + s * stepX * 0.9, y: neckY + armLen)
        let lElbow = CGPoint(x: (neck.x + lHand.x) / 2 - H * 0.02, y: neckY + armLen * 0.5)
        let rElbow = CGPoint(x: (neck.x + rHand.x) / 2 + H * 0.02, y: neckY + armLen * 0.5)

        func bone(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat, _ c: Color) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }

        // Ground shadow.
        let shadowW = H * 0.30
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - shadowW / 2, y: feetY + H * 0.01,
                                   width: shadowW, height: H * 0.05)),
            with: .color(.black.opacity(0.28))
        )

        bone(hip, neck, H * 0.055, color)                    // spine
        bone(hip, lKnee, H * 0.045, color); bone(lKnee, lFoot, H * 0.04, color)
        bone(hip, rKnee, H * 0.045, color); bone(rKnee, rFoot, H * 0.04, color)
        bone(neck, lElbow, H * 0.04, color); bone(lElbow, lHand, H * 0.032, color)
        bone(neck, rElbow, H * 0.04, color); bone(rElbow, rHand, H * 0.032, color)

        // Head.
        let headRect = CGRect(x: cx - headR, y: headCY - headR, width: headR * 2, height: headR * 2)
        ctx.fill(Path(ellipseIn: headRect), with: .color(color))
        ctx.stroke(Path(ellipseIn: headRect), with: .color(.white.opacity(0.9)), lineWidth: H * 0.012)
    }
}
