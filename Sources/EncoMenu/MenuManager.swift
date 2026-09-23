import AppKit
import SwiftUI
import EncoCore
import EncoBluetooth
import IOBluetooth

/// Owns the status item, the popover and all device state.
///
/// The SwiftUI view never holds state: after every change the manager rebuilds a
/// `PanelSnapshot` and reassigns `hosting.rootView`, which is what makes the panel work
/// without observation macros.
@MainActor
final class MenuManager: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let connectionNotice = ConnectionNotice()
    private var noticePolicy = ConnectionNoticePolicy()
    private var connectionNoticesEnabled = UserDefaults.standard.object(forKey: "connectionNoticesEnabled") as? Bool ?? true
    private let hosting: NSHostingController<PanelView>
    private let diagnosticsEnabled: Bool
    /// Explicit CLI appearance; `.system` keeps normal inheritance instead of locking a look.
    private let appearance: PanelAppearance

    private var transport: RFCOMMTransport?
    private var transactions: TransactionController?
    private var state = DeviceState()
    private var snapshot: PanelSnapshot

    private var connectionText = "未连接"
    private var connectionWarning: String?
    private var statusLine = "启动中…"
    /// Only real problems are surfaced, as one short orange line at the bottom of the panel.
    private var errorLine: String?
    private var showSettingsButton = false
    private var isConnecting = false
    private var isWorking = false
    private var lastAdvancedQueryAt: Date?

    private var pollTimer: Timer?
    private var reconnectTimer: Timer?
    /// Bluetooth warm-up bookkeeping. The first IOBluetooth call can block the calling thread
    /// while the framework initialises, so it never happens on the main thread.
    private var ready = false
    private var warmupStarted = false
    private var warmupTimer: Timer?
    private var warmupNotice: String?
    private var stopped = false
    private var backoffSteps: [TimeInterval] = [1, 3, 10, 20]
    private var backoffIndex = 0

    private let pollInterval: TimeInterval = 10
    private let advancedRefreshInterval: TimeInterval = 8
    private let openTimeout: TimeInterval = 8
    private var generation = 0
    private var refreshServices = false
    private let launchedAt = Date()

    init(appearance: PanelAppearance, diagnosticsEnabled: Bool) {
        self.appearance = appearance
        self.diagnosticsEnabled = diagnosticsEnabled
        self.snapshot = PanelSnapshot.empty()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.hosting = NSHostingController(rootView: PanelView(snapshot: snapshot, actions: PanelActions(
            onNoise: { _ in },
            onEqualizerMenu: {},
            onSpatialMenu: {},
            onRefresh: {},
            onAbout: {},
            onOpenSettings: {},
            onQuit: {}
        ), appearance: appearance))
        super.init()
    }

    func start() {
        if let button = statusItem.button {
            // Keep the native in-ear silhouette and its acoustic-port details at menu-bar size.
            // The previous tiny bitmap reduced both earbuds to two indistinct vertical stems.
            let symbol = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "Enco X3")
                ?? NSImage(systemSymbolName: "earbuds", accessibilityDescription: "Enco X3")
            button.image = symbol?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            button.image?.size = NSSize(width: 24, height: 18)
            button.setAccessibilityLabel("Enco X3")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        hosting.view.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height)
        popover.behavior = .transient
        popover.delegate = self
        // The popover and its hosting view do not reliably inherit NSApp.appearance set before
        // launch, so the explicit CLI value is written to both. `.system` leaves them untouched.
        if let nsAppearance = appearance.nsAppearance {
            popover.appearance = nsAppearance
            hosting.view.appearance = nsAppearance
            diag("appearance forced=\(appearance.rawValue)")
        } else {
            diag("appearance follows system")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // The read-only warm-up lets IOBluetooth initialise off the main thread before connecting.
        // A verified connection announces with a non-activating card. The full panel is opened
        // only by the user, so a background launch/reconnect cannot steal typing focus.
        render()
        beginBluetoothWarmup()
    }

    /// Starts the framework exactly once, off the main thread.
    ///
    /// The call exists only to complete IOBluetooth's internal initialisation; its result is used
    /// on that thread and dropped, so no device object ever crosses threads. The 5 second timer is
    /// a UI notice only — it does not cancel or restart the underlying call, and no further
    /// warm-up is ever scheduled.
    private func beginBluetoothWarmup() {
        guard !warmupStarted, !stopped else { return }
        warmupStarted = true
        connectionText = "准备连接"
        render()
        diag("warmup started")

        warmupTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, !self.ready else { return }
            self.warmupNotice = "系统蓝牙暂未响应，正在等待…"
            self.diag("warmup still pending after 5s")
            self.render()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = EncoDeviceLocator.pairedDevices()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.warmupTimer?.invalidate()
                self.warmupTimer = nil
                self.warmupNotice = nil
                self.ready = true
                self.diag("warmup complete")
                self.reconnectNow()
            }
        }
    }

    /// Brings the panel up (menu action, first launch, reopen). Activates the app so the panel
    /// accepts clicks right away; no extra window is created.
    func showPopover() {
        connectionNotice.hide()
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        diag("panel visible")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    /// Right-click menu; the plain click keeps opening the panel directly.
    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(menuOpenPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新读取", action: #selector(menuRefresh), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(menuQuit), keyEquivalent: "").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        showPopover()
    }

    @objc private func menuRefresh() {
        clearError()
        refresh(withQueries: true, force: true)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Sound row menus (AppKit)

    /// SwiftUI's `Menu` collapses a custom multi-element label down to bare text on macOS, which
    /// dropped the icon, the current value and the chevron. The rows are plain buttons instead and
    /// the menu is a real `NSMenu`, so the custom row keeps its full height and layout.
    private func popUpEqualizerMenu() {
        popUpMenu(
            row: snapshot.equalizerRow,
            action: #selector(equalizerMenuItemChosen(_:))
        )
    }

    private func popUpSpatialMenu() {
        popUpMenu(
            row: snapshot.spatialRow,
            action: #selector(spatialMenuItemChosen(_:))
        )
    }

    private func popUpMenu(row: PanelSnapshot.MenuRow, action: Selector) {
        let menu = NSMenu()
        for option in row.options {
            let item = NSMenuItem(title: option.title, action: action, keyEquivalent: "")
            item.target = self
            item.state = option.isSelected ? .on : .off
            item.representedObject = option.value
            menu.addItem(item)
        }
        let view = hosting.view
        let point: NSPoint
        if let event = NSApp.currentEvent {
            // Convert the click location into the panel's own coordinates.
            point = view.convert(event.locationInWindow, from: nil)
        } else {
            point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func equalizerMenuItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        performEqualizerWrite(id: id)
    }

    @objc private func spatialMenuItemChosen(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? Int else { return }
        performSpatialWrite(type: type)
    }

    /// A successful read or write clears the error line; the footer shows the update time instead.
    private func clearError() {
        errorLine = nil
    }

    private func setError(_ text: String) {
        errorLine = text
    }

    /// Optional `--diagnostics`: minimal connection/parsed-state lines on stderr. No device
    /// addresses, names or payloads, and nothing leaves the machine.
    func diag(_ message: String) {
        guard diagnosticsEnabled else { return }
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(launchedAt))
        FileHandle.standardError.write(Data("EncoMenu [\(elapsed)s] \(message)\n".utf8))
    }

    // MARK: - Menu bar plumbing

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            showPopover()
            // Opening the panel is an explicit request for current numbers: read everything.
            refresh(withQueries: true, force: true)
        }
    }

    @objc private func systemDidWake() {
        guard ready, !stopped else { return }
        clearError()
        render()
        // First launch: show the panel so the app is visible without hunting for the icon.
        // Scheduled on the main run loop, before any device work, and it never writes settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showPopover()
        }

        reconnectNow()
    }

    // MARK: - Connection

    private func reconnectNow() {
        guard ready, !stopped, !isConnecting else { return }
        Task { @MainActor [weak self] in await self?.connect() }
    }

    private func connect() async {
        guard ready, !stopped, !isConnecting else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        teardownSession(bumpBackoff: false)
        let token = generation
        isConnecting = true
        connectionText = "查找耳机"
        clearError()
        render()
        // Discovery may invoke system_profiler. It must never run on AppKit's thread.
        // Only the address value crosses back; no Bluetooth object is shared across threads.
        let address: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: EncoDeviceLocator.target()?.addressString)
            }
        }
        guard !stopped, generation == token else { return }
        guard let address, let device = IOBluetoothDevice(addressString: address) else {
            isConnecting = false
            connectionText = "未连接"
            showSettingsButton = true
            clearDeviceState()
            scheduleReconnect()
            return
        }
        showSettingsButton = false
        let transport = RFCOMMTransport(device: device)
        let transactions = TransactionController(transport: transport, defaultTimeout: 2)
        self.transport = transport
        self.transactions = transactions
        transport.onLog = { [weak self] in self?.diag($0) }
        transport.onState = { [weak self] status in
            guard let self, self.generation == token else { return }
            switch status {
            case .resolving: self.connectionText = "发现服务"
            case .opening: self.connectionText = "正在连接"
            case .closed, .failed:
                // An in-progress open has one failure owner: the catch below. Never arm two retries.
                guard !self.isConnecting else { return }
                self.transactions?.cancel()
                self.connectionText = "未连接"
                self.clearDeviceState()
                self.scheduleReconnect()
            default: break
            }
            self.render()
        }
        transport.onFrame = { [weak self, weak transactions] frame in
            guard let self, self.generation == token else { return }
            ResponseParser.apply(frame, to: &self.state)
            _ = transactions?.accept(frame)
            self.render()
        }
        do {
            try await transport.openAsync(refreshServices: refreshServices, openTimeout: openTimeout)
        } catch {
            guard !stopped, generation == token else { return }
            transport.onFrame = nil
            transport.onState = nil
            transactions.cancel()
            transport.close()
            self.transport = nil
            self.transactions = nil
            isConnecting = false
            refreshServices = true
            connectionText = "未连接"
            diag("open failed: \(error)")
            clearDeviceState()
            scheduleReconnect()
            return
        }
        guard !stopped, generation == token else { return }
        isConnecting = false
        refreshServices = false
        backoffIndex = 0
        connectionText = "已连接"
        clearError()
        diag("channel=open id=\(transport.channelID.map(String.init) ?? "?") elapsed=\(String(format: "%.3f", Date().timeIntervalSince(launchedAt)))s")
        isWorking = true
        render()
        _ = await transactions.queryAsync(cmd: EncoCommand.capability.rawValue)
        guard !stopped, generation == token else { return }
        isWorking = false
        startPolling()
        await refreshAsync(withQueries: true, force: true)
    }

    /// Closes this app's own control channel and drops every callback. Never touches the
    /// system pairing or the audio connection.
    private func teardownSession(bumpBackoff: Bool) {
        generation += 1
        noticePolicy.beginSession()
        connectionNotice.hide()
        transactions?.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
        if let transport {
            transport.onFrame = nil
            transport.onState = nil
            transport.onRawReceive = nil
            transport.onLog = nil
            transport.close()
        }
        transport = nil
        transactions = nil
        isWorking = false
        isConnecting = false
        if bumpBackoff { backoffIndex += 1 }
    }

    /// Called at termination: no timers, no observer, channel closed.
    func shutdown() {
        stopped = true
        ready = false
        warmupTimer?.invalidate()
        warmupTimer = nil
        warmupNotice = nil
        teardownSession(bumpBackoff: false)
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func scheduleReconnect() {
        let delay = backoffSteps[min(backoffIndex, backoffSteps.count - 1)]
        backoffIndex += 1
        setError("等待重连（\(Int(delay))s）")
        render()
        reconnectTimer?.invalidate()
        reconnectTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectNow()
        }
        RunLoop.main.add(reconnectTimer!, forMode: .common)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh(withQueries: true)
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func clearDeviceState() {
        connectionNotice.hide()
        state = DeviceState()
        lastAdvancedQueryAt = nil
        // The error line is deliberately kept: a disconnect sets it, and clearing state must not
        // erase the message explaining why the numbers disappeared.
        render()
    }

    // MARK: - Queries and writes

    /// All status values refresh about every 10s, including while a menu is tracking; a
    /// forced refresh reads everything. Values only ever come from received frames, never from
    /// an optimistic echo of our own write.
    private func refresh(withQueries: Bool, force: Bool = false) {
        Task { @MainActor [weak self] in await self?.refreshAsync(withQueries: withQueries, force: force) }
    }

    private func refreshAsync(withQueries: Bool, force: Bool = false) async {
        guard !isWorking else { return }
        guard let transactions, let transport, transport.state == .open else { return }
        isWorking = true
        let token = generation
        defer {
            if token == generation { isWorking = false; render() }
        }

        guard withQueries else { return }

        // A periodic tick must never erase a write failure the user should still see: only the
        // explicit user paths (manual refresh, a new write, a successful reconnect) clear it.

        _ = await transactions.queryAsync(cmd: EncoCommand.queryBattery.rawValue)
        _ = await transactions.queryAsync(
            cmd: EncoCommand.queryNoiseReduction.rawValue,
            payload: EncoPayload.noiseReductionCurrent
        )
        if state.productID == nil { _ = await transactions.queryAsync(cmd: EncoCommand.queryProductID.rawValue) }

        guard generation == token, !stopped else { return }
        let now = Date()
        let advancedAge = lastAdvancedQueryAt.map { now.timeIntervalSince($0) } ?? .infinity
        if force || advancedAge >= advancedRefreshInterval {
            lastAdvancedQueryAt = now
            _ = await transactions.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue)
            _ = await transactions.queryAsync(cmd: EncoCommand.querySpatial.rawValue)
            _ = await transactions.queryAsync(cmd: EncoCommand.queryEqAll.rawValue, payload: EncoPayload.eqAllQuery)
            _ = await transactions.queryAsync(cmd: EncoCommand.queryMultiConnect.rawValue)
            diag("refresh pid=\(state.productID != nil) anc=\(state.noiseReductionRawValue != nil) eq=\(state.equalizerPresetID.map(String.init) ?? "-") spatial=\(state.spatialType.map(String.init) ?? "-") eqList=\(state.equalizerPresets.count) devices=\(state.listedConnectedDevices.count)")
        }
    }

    private func performWrite(bitmap: UInt32) {
        Task { @MainActor [weak self] in await self?.performWriteAsync(bitmap: bitmap) }
    }

    private func performWriteAsync(bitmap: UInt32) async {
        guard let transactions else {
            setError("未连接")
            render()
            return
        }
        guard canWrite else {
            setError(noiseGate.reason ?? "暂不可设置")
            render()
            return
        }
        isWorking = true
        clearError()
        render()
        let token = generation
        defer { if generation == token { isWorking = false; render() } }
        let result = await transactions.setNoiseReductionAsync(bitmap: bitmap)
        guard generation == token, !stopped else { return }

        applyWriteResult(describeWriteResult(result, label: "降噪", target: result.targetRaw), result: result)
        // Re-read rather than assuming the device took the value.
        _ = await transactions.queryAsync(
            cmd: EncoCommand.queryNoiseReduction.rawValue,
            payload: EncoPayload.noiseReductionCurrent
        )
        render()
    }

    /// Single source of truth for the audio gate, used by the panel and by the setters so the
    /// button state and the actual write path cannot disagree.
    private var audioGate: (enabled: Bool, reason: String?) {
        guard !isWorking, !isConnecting else { return (false, "正在处理上一个请求") }
        guard let transport, transport.state == .open else { return (false, "未连接") }
        guard state.productID == X3Profile.productID else { return (false, "尚未确认耳机型号") }
        guard state.isFresh(state.equalizerUpdatedAt), state.isFresh(state.spatialUpdatedAt) else {
            return (false, "读数待刷新")
        }
        return (true, nil)
    }

    private var canWriteAudio: Bool { audioGate.enabled }

    private func performEqualizerWrite(id: Int) {
        Task { @MainActor [weak self] in await self?.performEqualizerWriteAsync(id: id) }
    }

    private func performEqualizerWriteAsync(id: Int) async {
        guard let transactions else {
            setError("未连接")
            render()
            return
        }
        guard canWriteAudio else {
            setError(audioGate.reason ?? "暂不可设置")
            render()
            return
        }
        guard X3Profile.measuredEqualizerPresetIDs.contains(id) else {
            setError("该 EQ 预设不可用")
            diag("eq write refused id=\(id) not in measured set")
            render()
            return
        }
        isWorking = true
        clearError()
        render()
        let token = generation
        defer { if generation == token { isWorking = false; render() } }
        let result = await transactions.setEqualizerAsync(id: id)
        guard generation == token, !stopped else { return }
        applyWriteResult(describeWriteResult(result, label: "EQ", target: UInt32(id)), result: result)
        _ = await transactions.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue)
        render()
    }

    private func performSpatialWrite(type: Int) {
        Task { @MainActor [weak self] in await self?.performSpatialWriteAsync(type: type) }
    }

    private func performSpatialWriteAsync(type: Int) async {
        guard let transactions else {
            setError("未连接")
            render()
            return
        }
        guard canWriteAudio else {
            setError(audioGate.reason ?? "暂不可设置")
            render()
            return
        }
        isWorking = true
        clearError()
        render()
        let token = generation
        defer { if generation == token { isWorking = false; render() } }
        let result = await transactions.setSpatialAsync(type: type)
        guard generation == token, !stopped else { return }
        applyWriteResult(describeWriteResult(result, label: "空间音效", target: UInt32(type)), result: result)
        _ = await transactions.queryAsync(cmd: EncoCommand.querySpatial.rawValue)
        render()
    }

    /// Short Chinese result for the panel; the technical detail goes to `--diagnostics`.
    /// Success needs no permanent text: the footer time and the selected state speak. A failure
    /// keeps one short orange line so the user knows the device did not take the request.
    private func applyWriteResult(_ text: String, result: TransactionResult) {
        switch result.outcome {
        case .verified:
            clearError()
        default:
            setError(text)
        }
    }

    private func describeWriteResult(_ result: TransactionResult, label: String, target: UInt32) -> String {
        diag("\(label) write target=\(target) outcome=\(result.outcome) detail=\(result.detail)")
        switch result.outcome {
        case .verified: return "\(label)已设置"
        case .normalized: return "设备返回其他模式，请查看当前状态"
        case .readbackMismatch: return "\(label)设置结果与请求不一致，请重新读取"
        case .rejected: return "设备拒绝了\(label)设置"
        case .malformedResponse: return "\(label)响应无法确认，未视为成功"
        case .timedOut: return "\(label)设置超时，未确认生效"
        case .notSent: return "\(label)未发出"
        }
    }

    /// Single source of truth for the noise-reduction gate. Every candidate value was accepted
    /// by the device with an exact readback (docs/evidence/2026-09-23-anc-verified.md), so no
    /// opt-in flag is needed; PID, channel, freshness and busy still gate it.
    private var noiseGate: (enabled: Bool, reason: String?) {
        guard !isWorking, !isConnecting else { return (false, "正在处理上一个请求") }
        guard let transport, transport.state == .open else { return (false, "未连接") }
        guard state.productID == X3Profile.productID else { return (false, "尚未确认耳机型号") }
        guard state.noiseReductionIsFresh() else { return (false, "读数待刷新") }
        return (true, nil)
    }

    private var canWrite: Bool { noiseGate.enabled }

    // MARK: - Snapshot

    private func render() {
        let now = Date()
        let batteryFresh = state.batteryIsFresh(now: now)

        var batteries: [PanelSnapshot.Battery] = []
        for slot in BatterySlot.allCases {
            let title: String
            let kind: ArtworkKind
            switch slot {
            case .left: title = "左耳"; kind = .earbudLeft
            case .right: title = "右耳"; kind = .earbudRight
            case .chargingCase: title = "充电盒"; kind = .chargingCase
            }
            let reading = state.battery[slot]
            batteries.append(PanelSnapshot.Battery(
                title: title,
                value: reading?.level.map { "\($0)%" } ?? "--",
                kind: kind,
                level: reading?.level,
                charging: reading?.charging ?? false,
                isStale: !batteryFresh,
                help: (slot == .chargingCase && reading?.level == nil) ? "盒盖打开且耳机入盒时可读取" : nil
            ))
        }

        // Noise control: the four buttons come from the profile, never from hardcoded bitmaps.
        let currentRaw = state.noiseReductionRawValue
        let activeLevel = X3Profile.selectedLevel(forRawBitmap: currentRaw)
        let levelSelected = currentRaw.map { raw in
            X3Profile.levelSpecs.contains { $0.bitmap == raw || $0.aliases.contains(raw) }
        } ?? false
        var modeControls: [PanelSnapshot.ModeControl] = []
        if let off = X3Profile.offSpec {
            modeControls.append(PanelSnapshot.ModeControl(
                id: "mode-off", value: Int(off.bitmap), title: off.label,
                symbol: SymbolAvailability.noiseOff,
                isSelected: off.bitmap == currentRaw || off.aliases.contains(currentRaw ?? 0),
                help: off.label
            ))
        }
        if let transparency = X3Profile.transparencySpec {
            modeControls.append(PanelSnapshot.ModeControl(
                id: "mode-transparency", value: Int(transparency.bitmap), title: "通透",
                symbol: SymbolAvailability.noiseTransparency,
                isSelected: transparency.bitmap == currentRaw || transparency.aliases.contains(currentRaw ?? 0),
                help: transparency.label
            ))
        }
        if let adaptive = X3Profile.adaptiveSpec {
            modeControls.append(PanelSnapshot.ModeControl(
                id: "mode-adaptive", value: Int(adaptive.bitmap), title: "自适应",
                symbol: SymbolAvailability.noiseAdaptive,
                isSelected: adaptive.bitmap == currentRaw || adaptive.aliases.contains(currentRaw ?? 0),
                help: adaptive.label
            ))
        }
        if let level = activeLevel {
            modeControls.append(PanelSnapshot.ModeControl(
                id: "mode-cancellation", value: Int(level.bitmap), title: "降噪",
                symbol: SymbolAvailability.noiseCancellation,
                isSelected: levelSelected,
                help: "降噪：当前档位 \(level.label)"
            ))
        }
        let levels: [PanelSnapshot.Selectable] = X3Profile.levelSpecs.map { spec in
            let short: String
            switch spec.key {
            case "Smart": short = "智能"
            case "Deep": short = "深度"
            case "Medium": short = "中度"
            case "Light": short = "轻度"
            default: short = spec.label
            }
            return PanelSnapshot.Selectable(
                id: "level-\(spec.protocolIndex)",
                value: Int(spec.bitmap),
                title: short,
                isSelected: spec.bitmap == currentRaw || spec.aliases.contains(currentRaw ?? 0)
            )
        }

        // Sound rows: names only, and only the values the device accepted with an exact readback.
        let devicePresets = state.equalizerPresets
        let eqOptions: [PanelSnapshot.Selectable] = X3Profile.measuredEqualizerPresetIDs.map { id in
            PanelSnapshot.Selectable(
                id: "eq-\(id)",
                value: id,
                title: X3Profile.equalizerName(id, devicePresets: devicePresets),
                isSelected: state.equalizerPresetID == id
            )
        }
        let spatialOptions: [PanelSnapshot.Selectable] = X3Profile.measuredSpatialTypes.map { type in
            PanelSnapshot.Selectable(
                id: "spatial-\(type)",
                value: type,
                title: X3Profile.spatialName(type),
                isSelected: state.spatialType == type
            )
        }

        var devices: [PanelSnapshot.DeviceRow] = []
        for (index, device) in state.listedConnectedDevices.enumerated() {
            let name = device.name.isEmpty ? "未知设备" : device.name
            devices.append(PanelSnapshot.DeviceRow(
                id: "device-\(index)",
                name: name,
                symbol: Self.deviceSymbol(forName: name),
                stateText: X3Profile.connectionStateName(device.connectionState),
                isConnected: device.connectionState == 2
            ))
        }

        let noise = noiseGate
        let audio = audioGate

        snapshot = PanelSnapshot(
            brand: "OPPO",
            title: "Enco X3",
            connectionText: connectionText,
            connectionOK: transport?.state == .open,
            batteries: batteries,
            modeControls: modeControls,
            noiseCurrentText: currentRaw.map { raw in
                X3Profile.interpretation(ofBitmap: raw).matchedLabel ?? "未知模式"
            } ?? "尚未读到",
            noiseEnabled: noise.enabled,
            noiseDisabledReason: noise.reason,
            levels: levels,
            levelsEnabled: noise.enabled,
            equalizerRow: PanelSnapshot.MenuRow(
                id: "eq", title: "均衡器", symbol: SymbolAvailability.equalizer, tint: .equalizer,
                currentText: state.equalizerPresetID.map { X3Profile.equalizerName($0, devicePresets: devicePresets) } ?? "未知",
                options: eqOptions, enabled: audio.enabled, help: "耳机自身的均衡器预设"
            ),
            spatialRow: PanelSnapshot.MenuRow(
                id: "spatial", title: "空间音效", symbol: SymbolAvailability.spatial, tint: .spatial,
                currentText: state.spatialType.map { X3Profile.spatialName($0) } ?? "未知",
                options: spatialOptions, enabled: audio.enabled,
                help: "耳机自身的空间音效模式，不等同 Apple 空间音频"
            ),
            audioEnabled: audio.enabled,
            audioDisabledReason: audio.reason,
            devices: devices,
            lastUpdateText: Self.footerTimestamp(state: state).map { "最近更新 \(TimestampText.clock($0))" } ?? "尚无数据",
            errorLine: errorLine ?? warmupNotice,
            busy: isWorking || isConnecting,
            showSettingsButton: showSettingsButton,
            connectionNoticesEnabled: connectionNoticesEnabled
        )
        renderIntoHost()
        if connectionNotice.isVisible { connectionNotice.update(snapshot: snapshot) }
        let noticeReady = transport?.state == .open && state.productID == X3Profile.productID && state.batteryIsFresh()
        if noticePolicy.shouldPresent(ready: noticeReady, enabled: connectionNoticesEnabled) {
            if !popover.isShown { presentConnectionNotice() }
        }
    }

    private func renderIntoHost() {
        let actions = PanelActions(
            onNoise: { [weak self] bitmap in self?.performWrite(bitmap: bitmap) },
            onEqualizerMenu: { [weak self] in self?.popUpEqualizerMenu() },
            onSpatialMenu: { [weak self] in self?.popUpSpatialMenu() },
            onRefresh: { [weak self] in
                // Explicit user refresh: this is the point where a stale error goes away.
                self?.clearError()
                self?.refresh(withQueries: true, force: true)
            },
            onAbout: { [weak self] in self?.showAbout() },
            onOpenSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            },
            onQuit: { NSApp.terminate(nil) },
            onPreviewConnectionNotice: { [weak self] in
                guard let self, self.snapshot.connectionOK else { return }
                self.popover.performClose(nil)
                self.presentConnectionNotice()
            },
            onToggleConnectionNotice: { [weak self] in
                guard let self else { return }
                self.connectionNoticesEnabled.toggle()
                UserDefaults.standard.set(self.connectionNoticesEnabled, forKey: "connectionNoticesEnabled")
                if !self.connectionNoticesEnabled { self.connectionNotice.hide() }
                self.render()
            }
        )
        // Re-assert the explicit appearance on every rootView swap; `.system` leaves it alone.
        if let nsAppearance = appearance.nsAppearance {
            hosting.view.appearance = nsAppearance
        }
        hosting.rootView = PanelView(snapshot: snapshot, actions: actions, appearance: appearance)
    }

    private func presentConnectionNotice() {
        connectionNotice.present(snapshot: snapshot, appearance: appearance) { [weak self] in self?.showPopover() }
        diag("connection notice shown")
    }

    /// About: what this app is, what it deliberately does not do, and the licence. Read-only.
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Enco X3 for Mac"
        alert.informativeText = """
        版本 \(Self.appVersion)（GPL-3.0-or-later；源码与来源见 README 与 docs/UPSTREAM.md）

        本应用只读取并调整 OPPO Enco X3 耳机自身的状态：电量、噪声控制、均衡器预设、
        耳机空间音效与双设备连接信息。

        不支持 Apple 生态能力：查找网络、iCloud 配对、Apple 设备自动切换，
        也不会出现系统 AirPods 弹窗。耳机的空间音效是耳机自身模式，不等同 Apple 空间音频。

        关闭本窗口不会向耳机写入任何内容。
        """
        alert.addButton(withTitle: "好")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Newest timestamp of a field that actually carries a value. A failed or unrelated response
    /// refreshes `lastResponseAt`, so that alone must not be reported as fresh data.
    static func footerTimestamp(state: DeviceState) -> Date? {
        [
            state.batteryUpdatedAt,
            state.noiseReductionUpdatedAt,
            state.equalizerUpdatedAt,
            state.spatialUpdatedAt,
            state.equalizerListUpdatedAt,
            state.productIDUpdatedAt,
            state.capabilityUpdatedAt,
            state.firmwareVersionUpdatedAt,
        ].compactMap { $0 }.max()
    }

    /// A laptop icon only when the reported name says so; anything else gets a generic wireless
    /// device icon, so a phone is never drawn as a computer.
    static func deviceSymbol(forName name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("mac") || lowered.contains("book") || lowered.contains("laptop") {
            return SymbolAvailability.computer
        }
        return SymbolAvailability.wirelessDevice
    }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
        return "\(short) (\(build))"
    }

}

enum TimestampText {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
