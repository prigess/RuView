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
            statItem(label: "Persons", value: "\(viewModel.snapshot?.persons.count ?? 0)")
            Divider().frame(height: 32)
            statItem(label: "Source", value: viewModel.sourceLabel)
            Divider().frame(height: 32)
            statItem(label: "Tick", value: viewModel.formattedTick)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.surface)
        .shadow(color: Color.steel.opacity(0.08), radius: 4, x: 0, y: 2)
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
            Text(viewModel.isConnected ? "No persons detected" : "Not connected")
                .font(.callout).foregroundColor(Color.steelLight.opacity(0.85))
            if viewModel.isConnected {
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
