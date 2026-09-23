import SwiftUI

/// Original, code-drawn artwork for the battery block: a generic in-ear bud (short stem, silicone
/// tip, metal collar, small sound port) and a rounded charging case. Nothing is copied from Apple
/// or from a product photo — these are simple shapes drawn with Path/Shape and gradients.
enum ArtworkKind {
    case earbudLeft
    case earbudRight
    case chargingCase
}

/// The bud body plus its short stem, drawn in a normalised 44×46 design box and mirrored for the
/// left unit. Keeping the design in one space and transforming the finished path keeps the drawing
/// readable (and the type checker happy).
private let artworkDesignSize = CGSize(width: 44, height: 46)

private func artworkTransform(in rect: CGRect, mirrored: Bool) -> [CGAffineTransform] {
    var transforms: [CGAffineTransform] = []
    if mirrored {
        transforms.append(CGAffineTransform(translationX: artworkDesignSize.width, y: 0).scaledBy(x: -1, y: 1))
    }
    transforms.append(CGAffineTransform(scaleX: rect.width / artworkDesignSize.width, y: rect.height / artworkDesignSize.height))
    transforms.append(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    return transforms
}

struct EarbudShape: Shape {
    var mirrored: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Body only: the part that sits in the ear concha. The stem is drawn separately behind it.
        path.addEllipse(in: CGRect(x: 9, y: 6, width: 26, height: 23))
        var result = path
        for transform in artworkTransform(in: rect, mirrored: mirrored) {
            result = result.applying(transform)
        }
        return result
    }
}

/// The silicone ear tip: a slightly offset capsule.
struct EarbudTipShape: Shape {
    var mirrored: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 22, y: 3, width: 14, height: 15))
        var result = path
        for transform in artworkTransform(in: rect, mirrored: mirrored) {
            result = result.applying(transform)
        }
        return result
    }
}

/// The charging case: a rounded body with a lid seam and a tiny status light.
struct CaseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: 5, y: 11, width: 34, height: 30),
            cornerSize: CGSize(width: 12, height: 12),
            style: .continuous
        )
        var result = path
        for transform in artworkTransform(in: rect, mirrored: false) {
            result = result.applying(transform)
        }
        return result
    }
}

/// Lid seam of the case, in design space.
struct CaseSeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7, y: 24))
        path.addLine(to: CGPoint(x: 37, y: 24))
        var result = path
        for transform in artworkTransform(in: rect, mirrored: false) {
            result = result.applying(transform)
        }
        return result
    }
}

struct EarbudArtwork: View {
    var kind: ArtworkKind

    var body: some View {
        ZStack {
            switch kind {
            case .earbudLeft, .earbudRight:
                let mirrored = kind == .earbudRight
                // Order matters and each part is opaque: the stem sits behind, the bud in front,
                // and nothing is stroked across parts (that is what drew crossing lines).
                StemArtwork(mirrored: mirrored)
                    .fill(metalGradient)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                EarbudTipShape(mirrored: mirrored)
                    .fill(tipGradient)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                EarbudShape(mirrored: mirrored)
                    .fill(bodyGradient)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                // Thin metal collar on the stem.
                Capsule()
                    .fill(collarGradient)
                    .frame(width: 9, height: 2)
                    .offset(x: mirrored ? 4 : -4, y: 7)
                // Sound port and microphone hole.
                Circle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: 3.2, height: 3.2)
                    .offset(x: mirrored ? 4.4 : -4.4, y: -1)
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 2.2, height: 2.2)
                    .offset(x: mirrored ? 4.2 : -4.2, y: 14)
            case .chargingCase:
                CaseShape()
                    .fill(caseGradient)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                CaseSeamShape()
                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
                // Single neutral status light: no evidence the case is charging, so no green.
                Circle()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: 3, height: 3)
                    .offset(y: 8)
            }
        }
        .frame(width: PanelMetrics.artworkWidth, height: PanelMetrics.artworkHeight)
    }

    /// Opaque near-white body so it reads as a solid earbud, not a transparent line drawing.
    private var bodyGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .white),
                Color(nsColor: .systemGray).opacity(0.55),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Silicone tip: light grey, slightly darker than the shell.
    private var tipGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .systemGray).opacity(0.75),
                Color(nsColor: .systemGray).opacity(0.45),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Brushed-metal stem.
    private var metalGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .white).opacity(0.98),
                Color(nsColor: .systemGray).opacity(0.7),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var collarGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .white).opacity(0.95),
                Color(nsColor: .systemGray).opacity(0.8),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var caseGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .white),
                Color(nsColor: .systemGray).opacity(0.5),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The stem on its own, so it can sit behind the bud without a shared outline.
struct StemArtwork: Shape {
    var mirrored: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 14.5, y: 22))
        path.addCurve(to: CGPoint(x: 15.5, y: 40), control1: CGPoint(x: 13.5, y: 29), control2: CGPoint(x: 13.5, y: 36))
        path.addCurve(to: CGPoint(x: 25.5, y: 40), control1: CGPoint(x: 17.5, y: 43.5), control2: CGPoint(x: 23.5, y: 43.5))
        path.addCurve(to: CGPoint(x: 24, y: 22), control1: CGPoint(x: 27, y: 36), control2: CGPoint(x: 25.5, y: 29))
        path.closeSubpath()
        var result = path
        for transform in artworkTransform(in: rect, mirrored: mirrored) {
            result = result.applying(transform)
        }
        return result
    }
}

/// Small battery outline with a proportional fill. Green only when a real capacity is known;
/// unknown is a hollow grey outline, never a fake level.
struct BatteryGlyph: View {
    var level: Int?
    var charging: Bool

    var body: some View {
        HStack(spacing: 13) {
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                        .frame(width: 17, height: 9)
                    if let level {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(fillColor)
                            .frame(width: max(2, 15 * CGFloat(max(0, min(100, level))) / 100), height: 5)
                            .padding(.leading, 1)
                    }
                }
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(strokeColor)
                    .frame(width: 1.6, height: 4)
            }
            .overlay(alignment: .center) {
                if charging {
                    Image(systemName: SymbolAvailability.bolt)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(PanelPalette.connected)
                        .offset(x: -1)
                }
            }
        }
        .frame(width: 20, height: 10)
    }

    private var strokeColor: Color {
        level == nil ? PanelPalette.tertiaryText : PanelPalette.secondaryText
    }

    private var fillColor: Color {
        level == nil ? Color.clear : PanelPalette.connected
    }
}
