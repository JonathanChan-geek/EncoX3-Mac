import AppKit
import SwiftUI
import EncoCore

/// Opt-in, offline visual fixtures. This path never creates MenuManager or touches Bluetooth.
/// The same production PanelView, sizes, artwork and actions are rendered, not a mock HTML UI.
@MainActor
final class PanelPreviewController: NSObject, NSApplicationDelegate {
    nonisolated static let states = ["light", "dark", "disconnected", "connecting", "equalizer", "spatial", "error"]
    private var snapshot: PanelSnapshot
    private let appearance: PanelAppearance
    private let popover = MenuPopover()
    private let statusItem: NSStatusItem
    private let host: NSHostingView<PanelView>

    init(state: String, appearance: PanelAppearance) {
        self.appearance = appearance
        snapshot = Self.fixture(state)
        host = NSHostingView(rootView: PanelView(snapshot: snapshot, actions: Self.emptyActions, appearance: appearance))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let controller = NSViewController()
        controller.view = host
        popover.contentViewController = controller
        popover.appearance = appearance.nsAppearance
        host.appearance = appearance.nsAppearance
        statusItem.button?.title = "Enco UI"
        statusItem.button?.toolTip = "Enco X3 离线 UI 预览（不连接蓝牙）"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        popover.onAnchorChange = { [weak self] x in self?.snapshot.anchorX = x; self?.update() }
        NSApp.delegate = self
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.togglePanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return true
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func update() {
        let actions = PanelActions(
            onNoise: { [weak self] value in
                guard let self else { return }
                for i in self.snapshot.modeControls.indices {
                    let mode = self.snapshot.modeControls[i]
                    self.snapshot.modeControls[i].isSelected = mode.value == Int(value) ||
                        (mode.id == "mode-cancellation" && X3Profile.levelSpecs.contains { $0.bitmap == value })
                }
                for i in self.snapshot.levels.indices { self.snapshot.levels[i].isSelected = self.snapshot.levels[i].value == Int(value) }
                self.update()
            },
            onEqualizerMenu: { [weak self] in self?.toggle("eq") },
            onSpatialMenu: { [weak self] in self?.toggle("spatial") },
            onRefresh: {}, onAbout: {}, onOpenSettings: {}, onQuit: { NSApp.terminate(nil) },
            onEqualizer: { [weak self] value in self?.select(value, equalizer: true) },
            onSpatial: { [weak self] value in self?.select(value, equalizer: false) }
        )
        let available = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(PanelMetrics.contentHeight(for: snapshot), available - 24)
        snapshot.viewportHeight = height
        host.rootView = PanelView(snapshot: snapshot, actions: actions, appearance: appearance)
        host.setFrameSize(NSSize(width: PanelMetrics.width, height: height))
        popover.contentSize = NSSize(width: PanelMetrics.width, height: height)
    }

    private func toggle(_ row: String) {
        snapshot.expandedAudioRow = snapshot.expandedAudioRow == row ? nil : row
        update()
    }

    private func select(_ value: Int, equalizer: Bool) {
        var row = equalizer ? snapshot.equalizerRow : snapshot.spatialRow
        for i in row.options.indices { row.options[i].isSelected = row.options[i].value == value }
        row.currentText = row.options.first { $0.value == value }?.title ?? "—"
        if equalizer { snapshot.equalizerRow = row } else { snapshot.spatialRow = row }
        update()
    }

    static var emptyActions: PanelActions {
        PanelActions(onNoise: { _ in }, onEqualizerMenu: {}, onSpatialMenu: {}, onRefresh: {}, onAbout: {}, onOpenSettings: {}, onQuit: {})
    }

    static func fixture(_ state: String) -> PanelSnapshot {
        var snapshot = PanelSnapshot.empty()
        let connected = state != "disconnected" && state != "connecting"
        snapshot.connectionOK = connected
        snapshot.connecting = state == "connecting"
        snapshot.connectionText = snapshot.displayedConnection
        snapshot.noiseEnabled = connected
        snapshot.levelsEnabled = connected
        snapshot.audioEnabled = connected
        snapshot.busy = snapshot.connecting
        for (i, level) in [86, 84, 72].enumerated() {
            snapshot.batteries[i].level = connected ? level : nil
            snapshot.batteries[i].value = connected ? "\(level)%" : "—"
            snapshot.batteries[i].isStale = !connected
        }
        let specs = [X3Profile.offSpec, X3Profile.transparencySpec, X3Profile.adaptiveSpec, X3Profile.defaultLevelSpec].compactMap { $0 }
        let ids = ["mode-off", "mode-transparency", "mode-adaptive", "mode-cancellation"]
        let titles = ["关闭", "通透", "自适应", "降噪"]
        let symbols = [SymbolAvailability.noiseOff, SymbolAvailability.noiseTransparency, SymbolAvailability.noiseAdaptive, SymbolAvailability.noiseCancellation]
        snapshot.modeControls = specs.enumerated().map { i, spec in
            .init(id: ids[i], value: Int(spec.bitmap), title: titles[i], symbol: symbols[i], isSelected: connected && i == 3, help: spec.label)
        }
        snapshot.levels = X3Profile.levelSpecs.enumerated().map { i, spec in
            .init(id: spec.key, value: Int(spec.bitmap), title: ["智能", "深度", "中度", "轻度"][i], isSelected: connected && i == 0)
        }
        snapshot.equalizerRow.currentText = connected ? "自定义" : "—"
        snapshot.equalizerRow.enabled = connected
        snapshot.equalizerRow.options = X3Profile.measuredEqualizerPresetIDs.map { id in
            .init(id: "eq-\(id)", value: id, title: id == 4 ? "自定义" : X3Profile.equalizerName(id), isSelected: id == 4)
        }
        snapshot.spatialRow.currentText = connected ? "关闭" : "—"
        snapshot.spatialRow.enabled = connected
        snapshot.spatialRow.options = X3Profile.measuredSpatialTypes.map { type in
            .init(id: "spatial-\(type)", value: type, title: X3Profile.spatialName(type), isSelected: type == 0)
        }
        if state == "equalizer" { snapshot.expandedAudioRow = "eq" }
        if state == "spatial" { snapshot.expandedAudioRow = "spatial" }
        if state == "error" { snapshot.errorLine = "读取超时，请重试。" }
        return snapshot
    }

    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in states {
            let appearance: PanelAppearance = name == "dark" ? .dark : .light
            NSApp.appearance = appearance.nsAppearance
            let snapshot = fixture(name)
            let view = PanelView(snapshot: snapshot, actions: emptyActions, appearance: appearance, usesMaterial: false)
            let size = NSSize(width: PanelMetrics.width, height: PanelMetrics.contentHeight(for: snapshot))
            let host = NSHostingView(rootView: view)
            host.appearance = appearance.nsAppearance
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance.nsAppearance
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "PanelPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法渲染 \(name)"])
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "PanelPreview", code: 2)
            }
            window.orderOut(nil)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
        }
    }
}
