import AppKit

/// A native key-capable accessory panel with the exact radius and anchor of the approved UI.
/// Keeps transient-popover behavior without stacking an opaque NSPopover bezel behind the glass.
@MainActor
final class MenuPopover: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var deactivation: NSObjectProtocol?
    private weak var anchorWindow: NSWindow?
    var onAnchorChange: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    var onLog: ((String) -> Void)?
    var isShown: Bool { panel.isVisible }
    var appearance: NSAppearance? {
        get { panel.appearance }
        set { panel.appearance = newValue }
    }
    var contentViewController: NSViewController? {
        get { panel.contentViewController }
        set { panel.contentViewController = newValue }
    }
    var contentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height) {
        didSet {
            let top = panel.frame.maxY
            panel.setContentSize(contentSize)
            if panel.isVisible { panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - contentSize.height)) }
        }
    }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        // A status-item click must work while another application is active. Do not
        // depend on the asynchronous NSApp activation handshake for the first click.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "Enco X3"
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
    }

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        guard let window = view.window else { return }
        anchorWindow = window
        let button = window.convertToScreen(view.convert(rect, to: nil))
        let screen = window.screen ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(button.midX - contentSize.width / 2, frame.minX + 8), frame.maxX - contentSize.width - 8)
        let top = button.minY + 1
        panel.setFrame(NSRect(x: x, y: top - contentSize.height, width: contentSize.width, height: contentSize.height), display: false)
        onAnchorChange?(button.midX - x)
        panel.makeKeyAndOrderFront(nil)
        onLog?("panel shown visible=\(panel.isVisible) key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
        installMonitors()
    }

    func performClose(_ sender: Any?) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeMonitors()
        onLog?("panel closed")
        onClose?()
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 && event.window === self.panel {
                self.performClose(nil)
                return nil
            }
            // The status item owns its own toggle. Native menu windows must keep tracking
            // so a click on a menu item is not swallowed by an early panel dismissal.
            if event.type != .keyDown && event.window !== self.panel && event.window !== self.anchorWindow,
               (event.window?.level.rawValue ?? 0) < NSWindow.Level.popUpMenu.rawValue {
                self.performClose(nil)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.performClose(nil)
        }
        // Nonactivating panels leave the current app active. Dismiss on a subsequent
        // application switch, not on our own application's activation/deactivation.
        deactivation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                             object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.performClose(nil) }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let deactivation { NSWorkspace.shared.notificationCenter.removeObserver(deactivation) }
        localMonitor = nil
        globalMonitor = nil
        deactivation = nil
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}
