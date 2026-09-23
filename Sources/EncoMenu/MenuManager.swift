import AppKit
import SwiftUI
import EncoCore
import EncoBluetooth

/// Owns the status item, the popover and all device state.
///
/// The SwiftUI view never holds state: after every change the manager rebuilds a
/// `PanelSnapshot` and reassigns `hosting.rootView`, which is what makes the panel work
/// without observation macros.
final class MenuManager: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hosting: NSHostingController<PanelView>
    private let diagnosticsEnabled: Bool

    private var transport: RFCOMMTransport?
    private var transactions: TransactionController?
    private var state = DeviceState()
    private var snapshot: PanelSnapshot

    private var connectionText = "未连接"
    private var connectionWarning: String?
    private var statusLine = "启动中…"
    /// Where the current status line came from: a read refresh must never overwrite the result
    /// of a write the user just triggered.
    private enum StatusSource { case placeholder, read, write }
    private var statusSource: StatusSource = .placeholder
    private var showSettingsButton = false
    private var isConnecting = false
    private var isWorking = false
    private var lastAdvancedQueryAt: Date?

    private var pollTimer: Timer?
    private var reconnectTimer: Timer?
    private var backoffSteps: [TimeInterval] = [5, 10, 20, 30]
    private var backoffIndex = 0

    private let pollInterval: TimeInterval = 10
    private let advancedRefreshInterval: TimeInterval = 15
    private let openTimeout: TimeInterval = 12

    init(diagnosticsEnabled: Bool) {
        self.diagnosticsEnabled = diagnosticsEnabled
        self.snapshot = PanelSnapshot.empty()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.hosting = NSHostingController(rootView: PanelView(snapshot: snapshot, actions: PanelActions(
            onNoise: { _ in },
            onEqualizer: { _ in },
            onSpatial: { _ in },
            onRefresh: {},
            onOpenSettings: {},
            onQuit: {}
        )))
        super.init()
    }

    func start() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Enco X3")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        hosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.behavior = .transient
        popover.delegate = self

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // First launch: bring the panel up once the first connect/read has run, scheduled on the
        // main run loop. It only reads; it never changes earbud settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showPopover()
        }

        reconnectNow()
    }

    /// Brings the panel up (menu action, first launch, reopen). Activates the app so the panel
    /// accepts clicks right away; no extra window is created.
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
        refresh(withQueries: true, force: true)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    /// Status line from a completed read; skipped while a write result is on screen.
    private func setReadStatus() {
        guard statusSource != .write else { return }
        statusSource = .read
        let dates = [state.batteryUpdatedAt, state.noiseReductionUpdatedAt].compactMap { $0 }
        if let updated = dates.max() {
            statusLine = state.isFresh(updated) ? "最近更新 \(TimestampText.clock(updated))" : "读数待刷新"
        } else {
            statusLine = "尚未收到有效状态，请重新读取"
        }
    }

    private func setWriteStatus(_ text: String) {
        statusSource = .write
        statusLine = text
    }

    /// Optional `--diagnostics`: minimal connection/parsed-state lines on stderr. No device
    /// addresses, names or payloads, and nothing leaves the machine.
    func diag(_ message: String) {
        guard diagnosticsEnabled else { return }
        FileHandle.standardError.write(Data("EncoMenu [diag] \(message)\n".utf8))
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
        statusLine = "系统唤醒，重新连接并查询…"
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
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        // Tear the previous session down completely before opening a new one, so a wake
        // notification cannot leave two transports (or two channels) alive.
        teardownSession(bumpBackoff: false)
        statusSource = .placeholder
        guard let device = EncoDeviceLocator.target() else {
            connectionText = "未连接"
            connectionWarning = EncoDeviceLocator.pairedDevices().isEmpty
                ? "未读取到蓝牙设备：可能缺少蓝牙权限"
                : "未找到已连接的 \(EncoDeviceLocator.targetName)"
            showSettingsButton = EncoDeviceLocator.pairedDevices().isEmpty
            statusLine = "本应用不会主动连接设备；请先在蓝牙设置中连接耳机"
            clearDeviceState()
            render()
            scheduleReconnect()
            return
        }

        isConnecting = true
        let transport = RFCOMMTransport(device: device)
        let transactions = TransactionController(transport: transport, defaultTimeout: 4)
        // [weak transactions] breaks the transport -> closure -> transactions -> transport cycle.
        transport.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .closed, .failed:
                self.diag("channel=\(state)")
                self.connectionText = "未连接"
                self.connectionWarning = "连接已断开，等待重连…"
                self.clearDeviceState()
                self.render()
                self.scheduleReconnect()
            default:
                break
            }
        }
        transport.onFrame = { [weak self, weak transactions] frame in
            guard let self else { return }
            ResponseParser.apply(frame, to: &self.state)
            _ = transactions?.accept(frame)
            self.render()
        }
        do {
            try transport.open(sdpTimeout: 10, openTimeout: openTimeout)
        } catch {
            transport.onFrame = nil
            transport.onState = nil
            transport.close()
            isConnecting = false
            connectionText = "未连接"
            connectionWarning = "连接失败，稍后重试"
            diag("open failed: \(error)")
            statusLine = "退避重试中"
            clearDeviceState()
            render()
            scheduleReconnect()
            return
        }
        self.transport = transport
        self.transactions = transactions
        isConnecting = false
        backoffIndex = 0
        connectionText = "已连接"
        connectionWarning = nil
        statusLine = "已连接，正在读取…"
        diag("channel=open id=\(transport.channelID.map(String.init) ?? "?")")
        // Same opening sequence as the probe path that works on this device: capability query
        // first (it is what brings the notifications up), then the first read of everything.
        _ = transactions.query(cmd: EncoCommand.capability.rawValue)
        startPolling()
        refresh(withQueries: true, force: true)
    }

    /// Closes this app's own control channel and drops every callback. Never touches the
    /// system pairing or the audio connection.
    private func teardownSession(bumpBackoff: Bool) {
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
        teardownSession(bumpBackoff: false)
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func scheduleReconnect() {
        let delay = backoffSteps[min(backoffIndex, backoffSteps.count - 1)]
        backoffIndex += 1
        statusLine = "\(Int(delay))s 后重试连接"
        render()
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectNow()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh(withQueries: true)
        }
    }

    private func clearDeviceState() {
        state = DeviceState()
        lastAdvancedQueryAt = nil
        statusSource = .placeholder
        render()
    }

    // MARK: - Queries and writes

    /// Basic values (battery, noise reduction) every 10s; the advanced block every ~20s (15s threshold on a 10s timer); a
    /// forced refresh reads everything. Values only ever come from received frames, never from
    /// an optimistic echo of our own write.
    private func refresh(withQueries: Bool, force: Bool = false) {
        guard !isWorking else { return }
        guard let transactions, let transport, transport.state == .open else { return }
        isWorking = true
        defer {
            isWorking = false
            render()
        }

        guard withQueries else { return }

        _ = transactions.query(cmd: EncoCommand.queryBattery.rawValue)
        _ = transactions.query(
            cmd: EncoCommand.queryNoiseReduction.rawValue,
            payload: EncoPayload.noiseReductionCurrent
        )
        if state.productID == nil { _ = transactions.query(cmd: EncoCommand.queryProductID.rawValue) }

        setReadStatus()
        let now = Date()
        let advancedAge = lastAdvancedQueryAt.map { now.timeIntervalSince($0) } ?? .infinity
        if force || advancedAge >= advancedRefreshInterval {
            lastAdvancedQueryAt = now
            _ = transactions.query(cmd: EncoCommand.queryEqualizer.rawValue)
            _ = transactions.query(cmd: EncoCommand.querySpatial.rawValue)
            _ = transactions.query(cmd: EncoCommand.queryEqAll.rawValue, payload: EncoPayload.eqAllQuery)
            _ = transactions.query(cmd: EncoCommand.queryMultiConnect.rawValue)
            diag("refresh pid=\(state.productID != nil) anc=\(state.noiseReductionRawValue != nil) eq=\(state.equalizerPresetID.map(String.init) ?? "-") spatial=\(state.spatialType.map(String.init) ?? "-") eqList=\(state.equalizerPresets.count) devices=\(state.listedConnectedDevices.count)")
        }
    }

    private func performWrite(bitmap: UInt32) {
        guard let transactions else {
            statusLine = "未连接"
            render()
            return
        }
        guard canWrite else {
            statusLine = noiseGate.reason ?? "暂不可设置"
            render()
            return
        }
        isWorking = true
        setWriteStatus("正在设置…")
        render()
        let result = transactions.setNoiseReduction(bitmap: bitmap)
        isWorking = false

        setWriteStatus(describeWriteResult(result, label: "降噪", target: result.targetRaw))
        // Re-read rather than assuming the device took the value.
        _ = transactions.query(
            cmd: EncoCommand.queryNoiseReduction.rawValue,
            payload: EncoPayload.noiseReductionCurrent
        )
        render()
    }

    /// Single source of truth for the audio gate, used by the panel and by the setters so the
    /// button state and the actual write path cannot disagree.
    private var audioGate: (enabled: Bool, reason: String?) {
        guard !isWorking else { return (false, "正在处理上一个请求") }
        guard let transport, transport.state == .open else { return (false, "未连接") }
        guard state.productID == X3Profile.productID else { return (false, "尚未确认耳机型号") }
        guard state.isFresh(state.equalizerUpdatedAt), state.isFresh(state.spatialUpdatedAt) else {
            return (false, "读数待刷新")
        }
        return (true, nil)
    }

    private var canWriteAudio: Bool { audioGate.enabled }

    private func performEqualizerWrite(id: Int) {
        guard let transactions else {
            statusLine = "未连接"
            render()
            return
        }
        guard canWriteAudio else {
            statusLine = audioGate.reason ?? "暂不可设置"
            render()
            return
        }
        guard X3Profile.measuredEqualizerPresetIDs.contains(id) else {
            statusLine = "该 EQ 预设不可用"
            diag("eq write refused id=\(id) not in measured set")
            render()
            return
        }
        isWorking = true
        setWriteStatus("正在切换 EQ 预设…")
        render()
        let result = transactions.setEqualizer(id: id)
        isWorking = false
        setWriteStatus(describeWriteResult(result, label: "EQ", target: UInt32(id)))
        _ = transactions.query(cmd: EncoCommand.queryEqualizer.rawValue)
        render()
    }

    private func performSpatialWrite(type: Int) {
        guard let transactions else {
            statusLine = "未连接"
            render()
            return
        }
        guard canWriteAudio else {
            statusLine = audioGate.reason ?? "暂不可设置"
            render()
            return
        }
        isWorking = true
        setWriteStatus("正在设置空间音效…")
        render()
        let result = transactions.setSpatial(type: type)
        isWorking = false
        setWriteStatus(describeWriteResult(result, label: "空间音效", target: UInt32(type)))
        _ = transactions.query(cmd: EncoCommand.querySpatial.rawValue)
        render()
    }

    /// Short Chinese result for the panel; the technical detail goes to `--diagnostics`.
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
        guard !isWorking else { return (false, "正在处理上一个请求") }
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
        let ancFresh = state.noiseReductionIsFresh(now: now)

        var batteries: [PanelSnapshot.Battery] = []
        var caseMissing = false
        for slot in BatterySlot.allCases {
            let title: String
            let symbol: String
            switch slot {
            case .left: title = "左耳"; symbol = "headphones"
            case .right: title = "右耳"; symbol = "headphones"
            case .chargingCase: title = "充电盒"; symbol = "battery.100"
            }
            if let reading = state.battery[slot] {
                let value = reading.level.map { "\($0)%" } ?? "--"
                batteries.append(PanelSnapshot.Battery(
                    title: title,
                    value: value,
                    symbol: symbol,
                    charging: reading.charging,
                    isStale: !batteryFresh
                ))
            } else {
                if slot == .chargingCase { caseMissing = true }
                batteries.append(PanelSnapshot.Battery(
                    title: title,
                    value: "--",
                    symbol: symbol,
                    charging: false,
                    isStale: !batteryFresh
                ))
            }
        }

        // Buttons come from the profile, never from hardcoded bitmaps. 关闭 / 通透 / 自适应通透
        // sit in one row; the four noise-cancellation levels go below in a two-column grid so
        // nothing overflows the 360pt panel.
        var primarySpecs = [X3Profile.offSpec, X3Profile.transparencySpec].compactMap { $0 }
        if let adaptive = X3Profile.adaptiveSpec { primarySpecs.append(adaptive) }
        let primaryNoiseOptions: [PanelSnapshot.Selectable] = primarySpecs.map { spec in
            PanelSnapshot.Selectable(
                id: "noise-\(spec.protocolIndex)",
                value: Int(spec.bitmap),
                title: spec.label,
                isSelected: spec.bitmap == state.noiseReductionRawValue
                    || spec.aliases.contains(state.noiseReductionRawValue ?? 0)
            )
        }
        let levelOptions: [PanelSnapshot.Selectable] = X3Profile.levelSpecs.map { spec in
            PanelSnapshot.Selectable(
                id: "level-\(spec.protocolIndex)",
                value: Int(spec.bitmap),
                title: spec.label,
                isSelected: spec.bitmap == state.noiseReductionRawValue
                    || spec.aliases.contains(state.noiseReductionRawValue ?? 0)
            )
        }

        var info: [PanelSnapshot.InfoRow] = []
        let listed = state.listedConnectedDevices
        for (index, device) in listed.enumerated() {
            info.append(PanelSnapshot.InfoRow(
                id: "device-\(index)",
                title: "已连接设备",
                value: device.name.isEmpty ? "未知设备" : device.name,
                detail: X3Profile.connectionStateName(device.connectionState)
            ))
        }

        // Audio pickers: names only, and only the preset ids the device accepted with an exact
        // readback. Unknown ids are never offered as write targets.
        let devicePresets = state.equalizerPresets
        let eqOptions: [PanelSnapshot.Selectable] = X3Profile.measuredEqualizerPresetIDs.map { id in
            PanelSnapshot.Selectable(
                id: "eq-\(id)",
                value: id,
                title: X3Profile.equalizerName(id, devicePresets: devicePresets),
                isSelected: state.equalizerPresetID == id
            )
        }
        let eqCurrentText: String = state.equalizerPresetID.map { id in
            X3Profile.equalizerName(id, devicePresets: devicePresets)
        } ?? "未知"
        let spatialOptions: [PanelSnapshot.Selectable] = X3Profile.measuredSpatialTypes.map { type in
            PanelSnapshot.Selectable(
                id: "spatial-\(type)",
                value: type,
                title: X3Profile.spatialName(type),
                isSelected: state.spatialType == type
            )
        }

        let noise = noiseGate
        let audio = audioGate

        snapshot = PanelSnapshot(
            title: "Enco X3",
            connectionText: connectionText,
            connectionOK: transport?.state == .open,
            lastUpdateText: state.lastResponseAt.map { "上次更新 \(TimestampText.clock($0))" } ?? "尚无数据",
            batteries: batteries,
            caseHint: caseMissing ? "盒盖打开且耳机入盒时可读取" : nil,
            primaryNoiseOptions: primaryNoiseOptions,
            levelOptions: levelOptions,
            noiseCurrentText: state.noiseReductionRawValue.map { raw in
                X3Profile.interpretation(ofBitmap: raw).matchedLabel ?? "未知模式"
            } ?? "尚未读到",
            noiseEnabled: noise.enabled,
            noiseDisabledReason: noise.reason,
            eqOptions: eqOptions,
            eqCurrentText: eqCurrentText,
            spatialOptions: spatialOptions,
            spatialCurrentText: state.spatialType.map { X3Profile.spatialName($0) } ?? "未知",
            audioEnabled: audio.enabled,
            audioDisabledReason: audio.reason,
            info: info,
            statusLine: statusLine,
            showSettingsButton: showSettingsButton,
            isBusy: isWorking
        )
        renderIntoHost()
    }

    private func renderIntoHost() {
        let actions = PanelActions(
            onNoise: { [weak self] bitmap in self?.performWrite(bitmap: bitmap) },
            onEqualizer: { [weak self] id in self?.performEqualizerWrite(id: id) },
            onSpatial: { [weak self] type in self?.performSpatialWrite(type: type) },
            onRefresh: { [weak self] in self?.refresh(withQueries: true, force: true) },
            onOpenSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            },
            onQuit: { NSApp.terminate(nil) }
        )
        hosting.rootView = PanelView(snapshot: snapshot, actions: actions)
    }
}

enum TimestampText {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
