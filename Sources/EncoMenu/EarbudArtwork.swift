import SwiftUI

enum ArtworkKind { case earbudLeft, earbudRight, chargingCase }

/// Original vector artwork, refined against the approved concept. No screenshot, wallpaper,
/// text, or controls are baked into assets; the shells stay sharp at every backing scale.
struct EarbudArtwork: View {
    var kind: ArtworkKind
    var width: CGFloat = 44
    var height: CGFloat = 44

    var body: some View {
        ZStack {
            if kind == .chargingCase { chargingCase } else { earbud }
        }
        .frame(width: 72, height: 66)
        .scaleEffect(x: width / 72, y: height / 66)
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private var earbud: some View {
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.99), Color(red: 0.74, green: 0.76, blue: 0.8)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 16, height: 36).rotationEffect(.degrees(-7)).offset(x: -3, y: 11)
                    .shadow(color: .black.opacity(0.12), radius: 2.5, y: 3)
                Ellipse()
                    .fill(LinearGradient(colors: [Color(white: 0.52), Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 23, height: 21).rotationEffect(.degrees(25)).offset(x: 7, y: -20)
                Ellipse()
                    .fill(LinearGradient(stops: [.init(color: .white, location: 0),
                                                .init(color: Color(red: 0.93, green: 0.94, blue: 0.96), location: 0.5),
                                                .init(color: Color(red: 0.75, green: 0.78, blue: 0.83), location: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 34).rotationEffect(.degrees(-30)).offset(x: -1, y: -11)
                    .shadow(color: .black.opacity(0.09), radius: 2.5, y: 2)
                Ellipse().fill(.white.opacity(0.35))
                    .frame(width: 17, height: 27).rotationEffect(.degrees(28)).offset(x: -11, y: -12)
                    .blur(radius: 1.5)
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 0.68, green: 0.71, blue: 0.76).opacity(0.64), .white.opacity(0.25)],
                                         startPoint: .topTrailing, endPoint: .bottomLeading))
                    .frame(width: 20, height: 18).rotationEffect(.degrees(25)).offset(x: 6, y: -20)
                Circle().fill(Color(red: 0.18, green: 0.2, blue: 0.26)).frame(width: 4.2, height: 4.2)
                    .offset(x: -7, y: -3)
                Capsule().fill(LinearGradient(colors: [Color(white: 0.65), .white], startPoint: .top, endPoint: .bottom))
                    .frame(width: 10, height: 1.5).rotationEffect(.degrees(-7)).offset(x: -4, y: 8)
                Capsule().fill(.white.opacity(0.7)).frame(width: 1.1, height: 18)
                    .rotationEffect(.degrees(-7)).offset(x: -9, y: 19)
            }
            .scaleEffect(x: kind == .earbudRight ? -1 : 1, y: 1)
            Text(kind == .earbudRight ? "R" : "L")
                .font(.system(size: 5.5, weight: .semibold))
                .foregroundStyle(Color(white: 0.51))
                .rotationEffect(.degrees(kind == .earbudRight ? 7 : -7))
                .offset(x: kind == .earbudRight ? 1.5 : -1.5, y: 22)
        }
    }

    private var chargingCase: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(LinearGradient(stops: [
                .init(color: Color(white: 0.995), location: 0),
                .init(color: Color(red: 0.95, green: 0.96, blue: 0.98), location: 0.45),
                .init(color: Color(red: 0.78, green: 0.8, blue: 0.85), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 67, height: 49)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.18), lineWidth: 0.4)
            }
            .overlay {
                Rectangle().fill(Color(red: 0.5, green: 0.54, blue: 0.62).opacity(0.65))
                    .frame(width: 55, height: 0.6).offset(y: -8)
                Circle().fill(Color(red: 0.34, green: 0.38, blue: 0.46))
                    .frame(width: 2.5, height: 2.5).offset(y: 5)
            }
            .shadow(color: .black.opacity(0.14), radius: 3, x: 0, y: 4)
            .offset(y: -1)
    }
}

/// A nil capacity is hollow; a genuine zero capacity has no artificial minimum fill.
struct BatteryGlyph: View {
    var level: Int?
    var charging: Bool
    var body: some View {
        HStack(spacing: 0.8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.4).strokeBorder(PanelPalette.secondaryText, lineWidth: 1)
                    .frame(width: 18, height: 9)
                if let level, level > 0 {
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(level <= 10 ? PanelPalette.warning : PanelPalette.connected)
                        .frame(width: 14 * CGFloat(min(100, level)) / 100, height: 5)
                        .padding(.leading, 2)
                }
            }
            Capsule().fill(PanelPalette.secondaryText).frame(width: 1.4, height: 3.5)
        }
        .frame(width: 21, height: 10)
        .overlay {
            if charging {
                Image(systemName: SymbolAvailability.bolt).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PanelPalette.primaryText).offset(x: -1)
            }
        }
        .accessibilityHidden(true)
    }
}
