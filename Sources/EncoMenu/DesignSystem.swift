import SwiftUI

enum PanelAppearance: String {
    case system, light, dark
    init?(flag: String) {
        guard flag == "light" || flag == "dark" else { return nil }
        self.init(rawValue: flag)
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

/// Point geometry measured from the approved Sunburst master, independent of display scale.
enum PanelMetrics {
    static let width: CGFloat = 380
    static let height: CGFloat = 548
    static let margin: CGFloat = 22
    static let cardRadius: CGFloat = 14
    static let innerPadding: CGFloat = 14
    static let rowHeight: CGFloat = 47
    static let optionHeight: CGFloat = 29
    static let artworkWidth: CGFloat = 72
    static let artworkHeight: CGFloat = 66
    static let hairline: CGFloat = 0.5

    static func contentHeight(for snapshot: PanelSnapshot) -> CGFloat {
        let count: Int
        switch snapshot.expandedAudioRow {
        case "eq": count = snapshot.equalizerRow.options.count
        case "spatial": count = snapshot.spatialRow.options.count
        default: count = 0
        }
        return height + CGFloat(count) * optionHeight + (snapshot.visibleError == nil ? 0 : 30)
    }
}

/// Adaptive explicit colors preserve the reference contrast instead of inheriting disabled
/// AppKit grays. Material is supplied separately; blue remains blue even with a custom accent.
enum PanelPalette {
    static func adaptive(_ light: UInt32, _ dark: UInt32, opacity: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: opacity)
        })
    }
    static var window: Color { adaptive(0xE8EDF5, 0x303946) }
    static var card: Color { adaptive(0xF8FAFF, 0x4A535F, opacity: 0.65) }
    static var quietFill: Color { adaptive(0xBFC9DA, 0x788493, opacity: 0.29) }
    static var cardStroke: Color { adaptive(0xFFFFFF, 0x87909E, opacity: 0.22) }
    static var divider: Color { adaptive(0x75849D, 0xB7C1D1, opacity: 0.25) }
    static var primaryText: Color { adaptive(0x111B2F, 0xF4F6FC) }
    static var secondaryText: Color { adaptive(0x59677E, 0xBEC7D5) }
    static var tertiaryText: Color { adaptive(0x7D899D, 0x929EAE) }
    static var selectedSegment: Color { adaptive(0xFFFFFF, 0x737D8B, opacity: 0.9) }
    static var accent: Color { Color(red: 0, green: 0.47, blue: 1) }
    static var connected: Color { Color(red: 0.04, green: 0.77, blue: 0.15) }
    static var disconnected: Color { tertiaryText }
    static var warning: Color { adaptive(0x986420, 0xE8BC78) }
    static var equalizerTint: Color { primaryText }
    static var spatialTint: Color { primaryText }
    static var deviceTint: Color { accent }
}

enum PanelFonts {
    static let brand = Font.system(size: 12, weight: .medium)
    static let title = Font.system(size: 22, weight: .semibold)
    static let section = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let micro = Font.system(size: 10)
}

struct SoftPressStyle: ButtonStyle {
    var cornerRadius: CGFloat = PanelMetrics.cardRadius
    var pressedScale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 26
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(PanelPalette.secondaryText)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Behind-window blur, not a baked-in wallpaper. The opaque tonal wash keeps text readable.
struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PopoverSilhouette: Shape {
    var anchorX: CGFloat = PanelMetrics.width / 2
    func path(in rect: CGRect) -> Path {
        let top: CGFloat = 9
        let r: CGFloat = 22
        let x = min(max(anchorX, r + 16), rect.width - r - 16)
        var p = Path()
        p.move(to: CGPoint(x: r, y: top))
        p.addLine(to: CGPoint(x: x - 14, y: top))
        p.addCurve(to: CGPoint(x: x, y: 0), control1: CGPoint(x: x - 5, y: top), control2: CGPoint(x: x - 5, y: 0))
        p.addCurve(to: CGPoint(x: x + 14, y: top), control1: CGPoint(x: x + 5, y: 0), control2: CGPoint(x: x + 5, y: top))
        p.addLine(to: CGPoint(x: rect.width - r, y: top))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: top + r), control: CGPoint(x: rect.width, y: top))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        p.addQuadCurve(to: CGPoint(x: rect.width - r, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: r, y: rect.height))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.height - r), control: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: top + r))
        p.addQuadCurve(to: CGPoint(x: r, y: top), control: CGPoint(x: 0, y: top))
        p.closeSubpath()
        return p
    }
}

struct PanelSurface: View {
    var anchorX: CGFloat
    var material: Bool = true
    var body: some View {
        ZStack {
            if material { PanelMaterial() }
            PanelPalette.window.opacity(material ? 0.87 : 1)
            LinearGradient(colors: [.white.opacity(0.13), .clear, PanelPalette.quietFill.opacity(0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(PopoverSilhouette(anchorX: anchorX))
        .overlay(PopoverSilhouette(anchorX: anchorX)
            .strokeBorderCompat(PanelPalette.adaptive(0xFFFFFF, 0xCFD7E6, opacity: 0.7)))
        .allowsHitTesting(false)
    }
}

private extension Shape {
    func strokeBorderCompat(_ color: Color) -> some View { stroke(color, lineWidth: 0.7).padding(0.4) }
}

enum SymbolAvailability {
    static func resolve(_ candidates: [String], fallback: String = "circle") -> String {
        candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? fallback
    }
    static let noiseOff = resolve(["nosign", "circle.slash"], fallback: "circle")
    static let noiseTransparency = resolve(["person.wave.2", "ear.badge.waveform"], fallback: "ear")
    static let noiseAdaptive = resolve(["sparkles"], fallback: "sparkle")
    static let noiseCancellation = resolve(["waveform"], fallback: "wave.3.right")
    static let equalizer = resolve(["slider.horizontal.3"], fallback: "line.3.horizontal")
    static let spatial = resolve(["dot.radiowaves.left.and.right"], fallback: "circle.dashed")
    static let computer = resolve(["laptopcomputer"], fallback: "display")
    static let wirelessDevice = resolve(["antenna.radiowaves.left.and.right"], fallback: "wifi")
    static let refresh = resolve(["arrow.triangle.2.circlepath", "arrow.clockwise"])
    static let more = "ellipsis"
    static let chevronDown = "chevron.down"
    static let bolt = "bolt.fill"
    static let check = "checkmark"
}
