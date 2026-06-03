import SwiftUI
import UIKit

// MARK: - Steel Blue Healthcare Design System
//
// All colors adapt automatically to light & dark mode via UIColor(dynamicProvider:).
// Hex codes in comments are: light / dark.

private func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? dark : light
    })
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> UIColor {
    UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
}

extension Color {
    // Brand / accent
    static let steel      = dyn(rgb(0.275, 0.510, 0.706), rgb(0.40, 0.66, 0.90))   // #4682B4 / #66A8E6
    static let steelDark  = dyn(rgb(0.173, 0.318, 0.510), rgb(0.30, 0.50, 0.78))   // #2C5282 / #4D7FC7
    static let steelLight = dyn(rgb(0.741, 0.835, 0.918), rgb(0.20, 0.28, 0.42))   // #BDD5EA / #33486B
    static let steelPale  = dyn(rgb(0.937, 0.957, 0.980), rgb(0.055, 0.082, 0.129))// #EFF4FA / #0E1521 (page bg)

    // Surface (cards) — replaces Color.white
    static let surface          = dyn(rgb(1.00, 1.00, 1.00),  rgb(0.105, 0.137, 0.212)) // #FFFFFF / #1B2336
    static let surfaceElevated  = dyn(rgb(1.00, 1.00, 1.00),  rgb(0.137, 0.180, 0.270)) // #FFFFFF / #232E45

    // Accent
    static let heartRed = dyn(rgb(0.878, 0.353, 0.353), rgb(0.95, 0.45, 0.45))     // #E05A5A / #F37272
    static let lungTeal = dyn(rgb(0.169, 0.651, 0.651), rgb(0.30, 0.78, 0.78))     // #2BA6A6 / #4DC7C7

    // Text
    static let healthText = dyn(rgb(0.102, 0.180, 0.290), rgb(0.92, 0.94, 0.97))   // #1A2E4A / #EAEFF7
    static let healthSub  = dyn(rgb(0.420, 0.498, 0.639), rgb(0.62, 0.69, 0.82))   // #6B7FA3 / #9EB0D1
}

// MARK: - Card modifier

struct RuCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.surface)
            .cornerRadius(16)
            .shadow(color: Color.steel.opacity(0.10), radius: 8, x: 0, y: 3)
    }
}

extension View {
    func ruCard(padding: CGFloat = 16) -> some View {
        modifier(RuCard(padding: padding))
    }
}

// MARK: - Gradient helpers

struct SteelGradient {
    static var main: LinearGradient {
        LinearGradient(colors: [.steel, .steelDark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var horizontal: LinearGradient {
        LinearGradient(colors: [.steel, .steelDark], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - LivePulseDot

/// Pulsing dot used to signal live, flowing data. Set `active = false` to freeze it.
struct LivePulseDot: View {
    var color: Color = .steel
    var size: CGFloat = 8
    var active: Bool = true

    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(pulsing && active ? 1.0 : 0.5)
                .opacity(pulsing && active ? 0.0 : 0.7)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)
            Circle()
                .fill(active ? color : Color.healthSub)
                .frame(width: size, height: size)
        }
        .onAppear { pulsing = true }
    }
}

// MARK: - MiniSparkline

/// Compact line + fill chart for showing recent history values.
struct MiniSparkline: View {
    let values: [Double]
    var color: Color = .steel
    var lineWidth: CGFloat = 1.6
    var showEndDot: Bool = true

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let lo = values.min()!
            let hi = values.max()!
            let range = (hi - lo) > 0.5 ? (hi - lo) : 1

            func pt(_ i: Int) -> CGPoint {
                CGPoint(
                    x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height * (1.0 - CGFloat((values[i] - lo) / range)) * 0.85 + size.height * 0.075
                )
            }

            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            fill.addLine(to: pt(0))
            for i in 1..<values.count { fill.addLine(to: pt(i)) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.12)))

            var line = Path()
            line.move(to: pt(0))
            for i in 1..<values.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(color.opacity(0.65)), lineWidth: lineWidth)

            if showEndDot {
                let last = pt(values.count - 1)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                    with: .color(color)
                )
            }
        }
    }
}

// MARK: - SectionHeader

/// Small uppercase, tracked label used above grouped cards — gives a clinical, organized feel.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(.healthSub)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundColor(.healthSub)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

// MARK: - Metric Status

/// Clinical status used to flag vitals against typical resting-adult ranges.
/// NOTE: WiFi-CSI sensing is non-medical — these labels are informational only.
enum MetricStatus {
    case normal, low, elevated, high, unknown

    var color: Color {
        switch self {
        case .normal:   return .steel
        case .low:      return .orange
        case .elevated: return .orange
        case .high:     return .heartRed
        case .unknown:  return .healthSub
        }
    }

    var label: String {
        switch self {
        case .normal:   return "Within typical range"
        case .low:      return "Below typical"
        case .elevated: return "Above typical"
        case .high:     return "Significantly elevated"
        case .unknown:  return "—"
        }
    }

    var icon: String {
        switch self {
        case .normal:   return "checkmark.seal.fill"
        case .low:      return "arrow.down.circle.fill"
        case .elevated: return "arrow.up.circle.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .unknown:  return "questionmark.circle"
        }
    }

    /// Resting adult heart rate.
    static func forHeartRate(_ bpm: Double) -> MetricStatus {
        if bpm < 50 { return .low }
        if bpm <= 100 { return .normal }
        if bpm <= 120 { return .elevated }
        return .high
    }

    /// Resting adult respiratory rate.
    static func forBreathingRate(_ rpm: Double) -> MetricStatus {
        if rpm < 10 { return .low }
        if rpm <= 20 { return .normal }
        if rpm <= 25 { return .elevated }
        return .high
    }
}

struct MetricStatusBadge: View {
    let status: MetricStatus
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon).font(.system(size: compact ? 9 : 11, weight: .semibold))
            Text(status.label)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(status.color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(status.color.opacity(0.12))
        .cornerRadius(6)
    }
}

// MARK: - Appearance mode

/// User-selectable appearance mode. Stored in `@AppStorage("appearanceMode")`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
