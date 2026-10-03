import SwiftUI

/// Pure presentation. Expanded state and all writes belong to the manager; only an explicit
/// option activation invokes a write. Selection always comes back from the device snapshot.
struct PanelView: View {
    let snapshot: PanelSnapshot
    let actions: PanelActions
    let appearance: PanelAppearance
    var usesMaterial: Bool = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
        }
        .frame(width: PanelMetrics.width,
               height: snapshot.viewportHeight ?? PanelMetrics.contentHeight(for: snapshot))
        .background(PanelSurface(anchorX: snapshot.anchorX, material: usesMaterial))
        .clipShape(PopoverSilhouette(anchorX: snapshot.anchorX))
        .preferredColorScheme(appearance.colorScheme)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.frame(height: 36)
            batteryBlock.padding(.top, 18)
            separator.padding(.top, 12)
            noiseControls.padding(.top, 14)
            audioCard.padding(.top, 14).padding(.horizontal, -8)
            bottomBar.padding(.top, 14)
            if let error = snapshot.visibleError {
                Text(error)
                    .font(PanelFonts.micro)
                    .foregroundStyle(PanelPalette.warning)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .help(error)
                    .accessibilityLabel("状态提示：\(error)")
            }
        }
        .padding(.horizontal, PanelMetrics.margin)
        .padding(.top, 29)
        .padding(.bottom, 12)
    }

    private var separator: some View {
        Rectangle().fill(PanelPalette.divider).frame(height: 0.5)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.brand).font(PanelFonts.brand).foregroundStyle(PanelPalette.secondaryText)
                Text(snapshot.title).font(PanelFonts.title).foregroundStyle(PanelPalette.primaryText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if snapshot.connecting && !snapshot.connectionOK {
                    ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 9, height: 9)
                } else {
                    Circle().fill(snapshot.connectionOK ? PanelPalette.connected : PanelPalette.disconnected)
                        .frame(width: 7, height: 7)
                }
                Text(snapshot.displayedConnection).font(PanelFonts.caption)
                    .foregroundStyle(PanelPalette.primaryText)
            }
            .padding(.top, 3)
            .accessibilityElement(children: .combine)
            moreMenu.padding(.top, 1)
        }
    }

    private var moreMenu: some View {
        Menu {
            if !snapshot.devices.isEmpty {
                Menu("双设备连接") {
                    ForEach(snapshot.devices, id: \.id) { device in
                        Label("\(device.name) · \(device.stateText)", systemImage: device.symbol)
                    }
                }
                Divider()
            }
            Button("日常体验与快捷键…", action: actions.onExperience)
            Divider()
            Button("刷新", action: actions.onRefresh).disabled(snapshot.busy)
            Toggle("连接时显示电量卡片", isOn: Binding(
                get: { snapshot.connectionNoticesEnabled }, set: { _ in actions.onToggleConnectionNotice() }
            ))
            Button("显示电量卡片", action: actions.onPreviewConnectionNotice).disabled(!snapshot.connectionOK)
            Button("关于 Enco X3", action: actions.onAbout)
            if snapshot.showSettingsButton {
                Button("打开系统设置…", action: actions.onOpenSettings)
            }
            Divider()
            Button("退出", action: actions.onQuit)
        } label: {
            Image(systemName: SymbolAvailability.more)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PanelPalette.primaryText)
                .frame(width: 18, height: 16)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("更多").accessibilityLabel("更多")
    }

    private var batteryBlock: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.batteries, id: \.title) { battery in
                VStack(spacing: 0) {
                    EarbudArtwork(kind: battery.kind, width: 72, height: 66)
                    Text(battery.title).font(PanelFonts.body)
                        .foregroundStyle(PanelPalette.primaryText)
                        .frame(height: 17).padding(.top, 9)
                    HStack(spacing: 6) {
                        BatteryGlyph(level: battery.isStale ? nil : battery.level,
                                     charging: !battery.isStale && battery.charging)
                        Text(battery.isStale || battery.level == nil ? "—" : battery.value)
                            .font(PanelFonts.value).monospacedDigit()
                            .foregroundStyle(PanelPalette.primaryText)
                    }
                    .frame(height: 18).padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .help(battery.help ?? (battery.isStale ? "读数待刷新" : ""))
            }
        }
        .frame(height: 116)
    }

    private var noiseControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("噪声控制").font(PanelFonts.section).foregroundStyle(PanelPalette.primaryText)
                .frame(height: 18)
            HStack(spacing: 8) {
                ForEach(snapshot.modeControls, id: \.id) { control in modeButton(control) }
            }
            .padding(.top, 8)
            Text("降噪强度").font(PanelFonts.caption).foregroundStyle(PanelPalette.secondaryText)
                .frame(height: 14).padding(.top, 14)
            levelSegments.padding(.top, 6)
        }
    }

    private func modeButton(_ control: PanelSnapshot.ModeControl) -> some View {
        let selected = snapshot.connectionOK && control.isSelected
        return Button { actions.onNoise(UInt32(control.value)) } label: {
            VStack(spacing: 10) {
                Image(systemName: control.symbol).font(.system(size: 23, weight: .regular))
                    .frame(height: 27)
                Text(control.title).font(PanelFonts.caption)
            }
            .foregroundStyle(selected ? .white : (snapshot.noiseEnabled ? PanelPalette.primaryText : PanelPalette.tertiaryText))
            .frame(maxWidth: .infinity).frame(height: 72)
            .background(selected ? PanelPalette.accent : PanelPalette.quietFill,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(SoftPressStyle(cornerRadius: 11))
        .modifier(PanelHover(enabled: snapshot.noiseEnabled, radius: 11))
        .disabled(!snapshot.noiseEnabled)
        .help(snapshot.noiseDisabledReason ?? control.help)
        .accessibilityLabel(control.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var levelSegments: some View {
        HStack(spacing: 0) {
            ForEach(Array(snapshot.levels.enumerated()), id: \.element.id) { index, level in
                let selected = snapshot.connectionOK && level.isSelected
                Button { actions.onNoise(UInt32(level.value)) } label: {
                    Text(level.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(snapshot.levelsEnabled ? PanelPalette.primaryText : PanelPalette.tertiaryText)
                        .frame(maxWidth: .infinity).frame(height: 29)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(PanelPalette.selectedSegment)
                                    .shadow(color: .black.opacity(0.09), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle(cornerRadius: 9, pressedScale: 1))
                .disabled(!snapshot.levelsEnabled)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .overlay(alignment: .leading) {
                    if index > 0 && !selected && !(snapshot.connectionOK && snapshot.levels[index - 1].isSelected) {
                        Rectangle().fill(PanelPalette.divider).frame(width: 0.5, height: 18)
                    }
                }
            }
        }
        .padding(1.5)
        .background(PanelPalette.quietFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .frame(height: 32)
    }

    private var audioCard: some View {
        VStack(spacing: 0) {
            audioSection(snapshot.equalizerRow, toggle: actions.onEqualizerMenu, select: actions.onEqualizer)
            separator.padding(.horizontal, 14)
            audioSection(snapshot.spatialRow, toggle: actions.onSpatialMenu, select: actions.onSpatial)
        }
        .background(PanelPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func audioSection(_ row: PanelSnapshot.MenuRow, toggle: @escaping () -> Void,
                              select: @escaping (Int) -> Void) -> some View {
        let expanded = snapshot.expandedAudioRow == row.id
        return VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: row.symbol).font(.system(size: 19, weight: .regular))
                        .frame(width: 24)
                    Text(row.title).font(PanelFonts.body)
                    Spacer(minLength: 4)
                    Text(snapshot.connectionOK && row.currentText != "未知" ? row.currentText : "—")
                        .font(PanelFonts.caption).foregroundStyle(PanelPalette.secondaryText)
                        .lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(PanelPalette.tertiaryText)
                }
                .foregroundStyle(PanelPalette.primaryText)
                .padding(.horizontal, 14).frame(height: PanelMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPressStyle(pressedScale: 1))
            .modifier(PanelHover(enabled: row.enabled, radius: 12))
            .disabled(!row.enabled)
            .help(row.help)
            .accessibilityLabel("\(row.title)，\(row.currentText)，\(expanded ? "已展开" : "展开选项")")
            if expanded {
                ForEach(row.options, id: \.id) { option in
                    Button { select(option.value) } label: {
                        HStack(spacing: 12) {
                            if row.id == "spatial" {
                                Image(systemName: spatialSymbol(option.value)).font(.system(size: 17))
                                    .frame(width: 24)
                            }
                            Text(option.title).font(PanelFonts.caption)
                            Spacer()
                            if option.isSelected {
                                Image(systemName: SymbolAvailability.check).font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(PanelPalette.accent)
                            }
                        }
                        .foregroundStyle(PanelPalette.primaryText)
                        .padding(.horizontal, 14).frame(height: PanelMetrics.optionHeight)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) { separator.padding(.horizontal, 14) }
                    }
                    .buttonStyle(SoftPressStyle(pressedScale: 1))
                    .modifier(PanelHover(enabled: row.enabled, radius: 6))
                    .disabled(!row.enabled)
                    .accessibilityAddTraits(option.isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func spatialSymbol(_ value: Int) -> String {
        switch value { case 0: return SymbolAvailability.noiseOff; case 1: return "globe"; default: return SymbolAvailability.spatial }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if snapshot.connecting && !snapshot.connectionOK {
                ProgressView().controlSize(.small).frame(width: 16, height: 18)
            } else {
                BluetoothMark().stroke(snapshot.connectionOK ? PanelPalette.accent : PanelPalette.tertiaryText,
                                       style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.connectionOK ? "已连接到 Mac" : (snapshot.connecting ? "正在连接耳机…" : "耳机未连接"))
                    .font(PanelFonts.caption).foregroundStyle(PanelPalette.secondaryText)
                if !snapshot.connectionOK && !snapshot.connecting {
                    Text("连接后可查看电量和设置").font(.system(size: 9)).foregroundStyle(PanelPalette.tertiaryText)
                }
            }
            Spacer(minLength: 0)
            if !snapshot.connectionOK && !snapshot.connecting {
                Button("重新连接", action: actions.onRefresh)
                    .font(.system(size: 11)).foregroundStyle(PanelPalette.accent)
                    .buttonStyle(.plain).disabled(snapshot.busy)
            }
            Button(action: actions.onRefresh) { Image(systemName: SymbolAvailability.refresh) }
                .buttonStyle(CircleIconButtonStyle()).disabled(snapshot.busy)
                .help("重新读取耳机状态").accessibilityLabel("刷新耳机状态")
        }
        .frame(height: 24)
        .help(snapshot.lastUpdateText)
    }
}

private struct PanelHover: ViewModifier {
    var enabled: Bool
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.overlay(HoverTrackingView(enabled: enabled, radius: radius).accessibilityHidden(true))
    }
}

/// AppKit tracking avoids requiring SwiftUI's newer State macro plugin in the CLT-only build.
private struct HoverTrackingView: NSViewRepresentable {
    var enabled: Bool
    var radius: CGFloat
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.enabled = enabled
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        if !enabled { view.layer?.backgroundColor = nil }
    }
    final class TrackingView: NSView {
        var enabled = true
        private var tracking: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) {
            if enabled { layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.055).cgColor }
        }
        override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    }
}

struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.1 * rect.width, y: 0.22 * rect.height))
        p.addLine(to: CGPoint(x: 0.88 * rect.width, y: 0.72 * rect.height))
        p.addLine(to: CGPoint(x: 0.48 * rect.width, y: 0.98 * rect.height))
        p.addLine(to: CGPoint(x: 0.48 * rect.width, y: 0.02 * rect.height))
        p.addLine(to: CGPoint(x: 0.88 * rect.width, y: 0.28 * rect.height))
        p.addLine(to: CGPoint(x: 0.1 * rect.width, y: 0.78 * rect.height))
        return p
    }
}
