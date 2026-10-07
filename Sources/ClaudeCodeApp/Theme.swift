import SwiftUI

/// Entrel Code's visual identity: warm graphite surfaces, hairline borders and a
/// single terracotta accent. The app is dark-only by design.
enum Theme {
    static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: opacity)
    }

    // Surfaces, from the window canvas up to hover highlights.
    static let canvas = hex(0x0D0D0E)
    static let surfaceLowest = hex(0x111112)
    static let surface = hex(0x161618)
    static let surfaceHover = hex(0x1D1D20)
    static let elevated = hex(0x212124)
    static let highlight = hex(0x2A2A2E)
    static let codeInset = hex(0x0E0E10)

    // Hairlines.
    static let border = hex(0x26262A)
    static let subtle = hex(0x323238)
    static let divider = hex(0x1E1E22)

    // Text.
    static let textPrimary = hex(0xECECED)
    static let textBody = hex(0xD6D6D9)
    static let textSecondary = hex(0x8E8E93)
    static let textMuted = hex(0x636366)

    // Brand and semantics.
    static let brand = hex(0xD97745)
    static let brandHover = hex(0xE58856)
    static let success = hex(0x4E9E67)
    static let successText = hex(0x76C291)
    static let error = hex(0xCF5C5C)
    static let errorText = hex(0xE07A76)
    static let addedBackground = hex(0x4E8F67, 0.14)
    static let removedBackground = hex(0xB8534F, 0.16)
}

/// The "elo" mark: a spine with two rails and the terracotta link between them.
struct EntrelMark: View {
    var spine = Theme.hex(0xE6E6E8)
    var link = Theme.brand

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)

            context.fill(Path(roundedRect: CGRect(x: 20, y: 16, width: 12, height: 68), cornerRadius: 6),
                         with: .color(spine))
            var top = Path()
            top.move(to: CGPoint(x: 26, y: 22))
            top.addLine(to: CGPoint(x: 68, y: 22))
            top.addCurve(to: CGPoint(x: 80, y: 34), control1: CGPoint(x: 74.6, y: 22), control2: CGPoint(x: 80, y: 27.4))
            top.addCurve(to: CGPoint(x: 68, y: 46), control1: CGPoint(x: 80, y: 40.6), control2: CGPoint(x: 74.6, y: 46))
            top.addLine(to: CGPoint(x: 30, y: 46))
            context.stroke(top, with: .color(spine), style: stroke)

            var middle = Path()
            middle.move(to: CGPoint(x: 26, y: 50))
            middle.addLine(to: CGPoint(x: 62, y: 50))
            middle.addCurve(to: CGPoint(x: 74, y: 62), control1: CGPoint(x: 68.6, y: 50), control2: CGPoint(x: 74, y: 55.4))
            middle.addCurve(to: CGPoint(x: 62, y: 74), control1: CGPoint(x: 74, y: 68.6), control2: CGPoint(x: 68.6, y: 74))
            middle.addLine(to: CGPoint(x: 30, y: 74))
            context.stroke(middle, with: .color(link), style: stroke)

            var bottom = Path()
            bottom.move(to: CGPoint(x: 26, y: 78))
            bottom.addLine(to: CGPoint(x: 72, y: 78))
            context.stroke(bottom, with: .color(spine), style: stroke)
        }
    }
}

/// A small status dot; pulses while the agent is active.
struct StatusBead: View {
    var color = Theme.brand
    var pulsing = false
    var size: CGFloat = 7
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: pulsing ? color.opacity(0.7) : .clear, radius: 4)
            .opacity(pulsing && dim ? 0.35 : 1)
            .onAppear { animate() }
            .onChange(of: pulsing) { _ in animate() }
    }

    private func animate() {
        guard pulsing else { dim = false; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// The standard bordered container used for tool output, diffs and status blocks.
struct CardStyle: ViewModifier {
    var background = Theme.surfaceLowest
    var border = Theme.border
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(background))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    func card(background: Color = Theme.surfaceLowest, border: Color = Theme.border, radius: CGFloat = 10) -> some View {
        modifier(CardStyle(background: background, border: border, radius: radius))
    }
}

/// Buttons in the three weights the design uses: brand (primary), elevated and ghost.
struct EntrelButtonStyle: ButtonStyle {
    enum Kind { case brand, elevated, ghost }
    var kind: Kind = .elevated
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 7).fill(background(pressed: configuration.isPressed)))
            .overlay {
                if kind == .elevated { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border) }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .brand: return .white
        case .elevated: return Theme.textPrimary
        case .ghost: return hovering ? Theme.textPrimary : Theme.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .brand: return hovering || pressed ? Theme.brandHover : Theme.brand
        case .elevated: return hovering || pressed ? Theme.highlight : Theme.elevated
        case .ghost: return hovering || pressed ? Theme.elevated : .clear
        }
    }
}

extension ButtonStyle where Self == EntrelButtonStyle {
    static var brand: EntrelButtonStyle { EntrelButtonStyle(kind: .brand) }
    static var elevated: EntrelButtonStyle { EntrelButtonStyle(kind: .elevated) }
    static var ghost: EntrelButtonStyle { EntrelButtonStyle(kind: .ghost) }
}

/// Keyboard key hint, like the "Return" chip under the composer.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
    }
}
