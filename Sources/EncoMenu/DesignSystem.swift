import SwiftUI

/// Explicit appearance requested on the command line. Defaults to following the system; nothing
/// here locks a light or dark look unless it was actually asked for.
enum PanelAppearance: String {
    case system
    case light
    case dark

    init?(flag: String) {
        switch flag {
        case "light": self = .light
        case "dark": self = .dark
        default: return nil
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Fixed geometry for the panel. One place so the three sizes stay consistent.
enum PanelMetrics {
    static let width: CGFloat = 380
    /// Design height. The stacked content is measured to fit inside this without clipping or a
    /// scrollbar; it is the single source for the panel frame and the popover size.
    static let height: CGFloat = 580
    /// Outer margin of the whole panel.
    static let margin: CGFloat = 16
    /// Vertical gap between the main blocks.
    static let spacing: CGFloat = 10

    static let cardRadius: CGFloat = 18
    static let innerPadding: CGFloat = 12
    static let rowHeight: CGFloat = 44
    static let modeIconSize: CGFloat = 38
    /// Tap target for the mode buttons, comfortably above the 44pt guideline.
    static let modeTapHeight: CGFloat = 46

    /// Top bar, battery row, device rows and footer heights, so the total stays predictable.
    static let topBarHeight: CGFloat = 38
    static let batteryBlockHeight: CGFloat = 88
    static let deviceRowHeight: CGFloat = 22
    static let footerHeight: CGFloat = 26
    static let noiseCardSpacing: CGFloat = 8
    static let levelSegmentHeight: CGFloat = 26
    static let artworkWidth: CGFloat = 44
    static let artworkHeight: CGFloat = 46
    /// Reserved strip under the footer for a one-line problem message. Always present, so the
    /// layout never jumps when a message appears.
    static let errorSlotHeight: CGFloat = 20

    static let hairline: CGFloat = 0.5
}

/// Semantic colours, so light and dark both work without touching the system appearance.
enum PanelPalette {
    /// Overlays the popover's system material with a near-white / near-black surface.
    static var window: Color { Color(nsColor: .windowBackgroundColor) }
    /// The three main blocks: white in light mode, elevated grey in dark mode.
    static var card: Color { Color(nsColor: .textBackgroundColor) }
    /// Quiet fill for the device card and the unselected mode buttons.
    static var quietFill: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.18) }
    static var cardStroke: Color { Color(nsColor: .separatorColor).opacity(0.45) }
    static var divider: Color { Color(nsColor: .separatorColor).opacity(0.5) }

    static var primaryText: Color { Color(nsColor: .labelColor) }
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }

    static var accent: Color { Color(nsColor: .controlAccentColor) }
    static var connected: Color { Color(nsColor: .systemGreen) }
    static var disconnected: Color { Color(nsColor: .tertiaryLabelColor) }
    static var warning: Color { Color(nsColor: .systemOrange) }

    /// Icon tints for the two sound rows.
    static var equalizerTint: Color { Color(nsColor: .systemTeal) }
    static var spatialTint: Color { Color(nsColor: .systemIndigo) }
    static var deviceTint: Color { Color(nsColor: .systemBlue) }
}

/// System fonts at the sizes the panel uses.
enum PanelFonts {
    static let brand = Font.system(size: 11, weight: .medium)
    static let title = Font.system(size: 20, weight: .semibold)
    static let section = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 15, weight: .medium)
    static let caption = Font.system(size: 11)
    static let micro = Font.system(size: 10)
}

/// Plain, self-drawn press feedback: no grey AppKit rectangles anywhere in the panel.
struct SoftPressStyle: ButtonStyle {
    var cornerRadius: CGFloat = PanelMetrics.cardRadius
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Round icon button used by the top bar and the footer.
struct CircleIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PanelPalette.secondaryText)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(PanelPalette.quietFill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A content block: rounded, unobtrusive stroke instead of heavy dividers.
struct PanelCard<Content: View>: View {
    var radius: CGFloat = PanelMetrics.cardRadius
    var padding: CGFloat = PanelMetrics.innerPadding
    var fill: Color = PanelPalette.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(PanelPalette.cardStroke, lineWidth: PanelMetrics.hairline)
            )
    }
}

/// Resolves an SF Symbol at runtime, falling back through candidates rather than drawing a blank.
enum SymbolAvailability {
    static func resolve(_ candidates: [String], fallback: String = "circle") -> String {
        for name in candidates where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return fallback
    }

    /// Noise-control symbols, validated once at launch.
    static let noiseOff = resolve(["xmark.circle", "xmark.circle.fill"], fallback: "circle")
    static let noiseTransparency = resolve(["person.wave.2", "person.wave.2.fill"], fallback: "person")
    static let noiseAdaptive = resolve(["sparkles", "wand.and.stars"], fallback: "sparkle")
    static let noiseCancellation = resolve(["waveform", "waveform.circle"], fallback: "wave.3.right")
    static let equalizer = resolve(["slider.horizontal.3", "slider.horizontal.below.rectangle"], fallback: "line.3.horizontal")
    static let spatial = resolve(["circle.hexagongrid", "dot.radiowaves.left.and.right"], fallback: "circle.dashed")
    static let computer = resolve(["laptopcomputer", "desktopcomputer"], fallback: "display")
    /// Generic handheld / wireless device — a phone must never be drawn as a laptop.
    static let wirelessDevice = resolve(["antenna.radiowaves.left.and.right", "wifi"], fallback: "circle")
    static let refresh = resolve(["arrow.clockwise"], fallback: "arrow.triangle.2.circlepath")
    static let more = resolve(["ellipsis", "ellipsis.circle"], fallback: "circle")
    static let chevronDown = resolve(["chevron.down", "arrowtriangle.down.fill"], fallback: "chevron.right")
    static let bolt = resolve(["bolt.fill", "bolt"], fallback: "circle")
    static let check = resolve(["checkmark", "checkmark.circle.fill"], fallback: "checkmark")
}
