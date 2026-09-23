import AppKit
import SwiftUI

/// A local connection card. Non-activating: background reconnects never steal keyboard focus.
@MainActor
final class ConnectionNotice {
    private let panel: NSPanel
    private let host: NSHostingView<ConnectionNoticeView>
    private var dismissal: Timer?
    private var appearance: PanelAppearance = .system
    private var message: String?
    private var onOpen: () -> Void = {}
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 336, height: 212),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Enco X3 连接电量"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        host = NSHostingView(rootView: ConnectionNoticeView(snapshot: .empty(), appearance: .system, message: nil, onOpen: {}, onClose: {}))
        panel.contentView = host
    }

    func present(snapshot: PanelSnapshot, appearance: PanelAppearance, message: String? = nil, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        self.appearance = appearance
        self.message = message
        panel.appearance = appearance.nsAppearance
        host.appearance = appearance.nsAppearance
        update(snapshot: snapshot)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 20,
                                     y: area.maxY - panel.frame.height - 16))
        panel.orderFrontRegardless()
        dismissal?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func update(snapshot: PanelSnapshot) {
        host.rootView = ConnectionNoticeView(snapshot: snapshot, appearance: appearance, message: message, onOpen: { [weak self] in
            self?.hide()
            self?.onOpen()
        }, onClose: { [weak self] in self?.hide() })
    }

    func hide() {
        dismissal?.invalidate()
        dismissal = nil
        panel.orderOut(nil)
    }
}

private struct ConnectionNoticeView: View {
    let snapshot: PanelSnapshot
    let appearance: PanelAppearance
    let message: String?
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "airpodspro").font(.system(size: 25))
                    .foregroundStyle(PanelPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enco X3").font(.system(size: 17, weight: .semibold))
                    Text(message ?? "已连接").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(message ?? "已连接")
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("关闭连接提示")
            }
            HStack(spacing: 0) {
                ForEach(snapshot.batteries, id: \.title) { battery in
                    VStack(spacing: 3) {
                        EarbudArtwork(kind: battery.kind)
                        Text(battery.title).font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(battery.value).font(.system(size: 15, weight: .medium, design: .rounded))
                            BatteryGlyph(level: battery.isStale ? nil : battery.level, charging: battery.charging)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            Button("打开控制面板", action: onOpen)
                .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                .foregroundStyle(PanelPalette.accent)
        }
        .padding(18)
        .frame(width: 336, height: 212)
        .background(PanelPalette.window, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .preferredColorScheme(appearance.colorScheme)
    }
}
