import SwiftUI

/// The panel itself. Pure rendering of `PanelSnapshot`: no state, no property wrappers, no
/// observation macros. Every affordance is a plain, self-drawn button or a real menu; nothing in
/// here can write to the device on its own.
struct PanelView: View {
    let snapshot: PanelSnapshot
    let actions: PanelActions
    /// Plain value (no property wrapper): nil means follow the system appearance.
    let appearance: PanelAppearance

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
        }
        // One fixed frame for the whole panel; the background fills it, so no grey strips appear
        // at the sides from a second, narrower frame around the padded content.
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background(PanelPalette.window)
        .preferredColorScheme(appearance.colorScheme)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.spacing) {
            topBar
            batteryBlock
            noiseCard
            audioCard
            if !snapshot.devices.isEmpty {
                deviceCard
            }
            // Footer and the reserved message strip travel together with a tight gap, so the
            // panel stays inside PanelMetrics.height while a message can still be shown.
            VStack(alignment: .leading, spacing: 2) {
                bottomBar
                errorSlot
            }
        }
        .padding(PanelMetrics.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fixed-height strip under the footer: empty in normal use, so nothing moves when a short
    /// problem message appears, and it can never overlap the footer.
    private var errorSlot: some View {
        Group {
            if let error = snapshot.errorLine {
                Text(error)
                    .font(PanelFonts.caption)
                    .foregroundStyle(PanelPalette.warning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text(" ")
                    .font(PanelFonts.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PanelMetrics.errorSlotHeight, alignment: .leading)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.brand)
                    .font(PanelFonts.brand)
                    .foregroundStyle(PanelPalette.tertiaryText)
                    .tracking(0.6)
                Text(snapshot.title)
                    .font(PanelFonts.title)
                    .foregroundStyle(PanelPalette.primaryText)
            }
            Spacer(minLength: 8)
            statusPill
            moreMenu
        }
        .frame(height: PanelMetrics.topBarHeight, alignment: .top)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(snapshot.connectionOK ? PanelPalette.connected : PanelPalette.disconnected)
                .frame(width: 7, height: 7)
            Text(snapshot.connectionText)
                .font(PanelFonts.caption)
                .foregroundStyle(snapshot.connectionOK ? PanelPalette.primaryText : PanelPalette.secondaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(PanelPalette.quietFill))
        .padding(.top, 3)
    }

    private var moreMenu: some View {
        Menu {
            Button("刷新") { actions.onRefresh() }
            Button("关于 Enco X3") { actions.onAbout() }
            if snapshot.showSettingsButton {
                Divider()
                Button("打开系统设置…") { actions.onOpenSettings() }
            }
            Divider()
            Button("退出") { actions.onQuit() }
        } label: {
            Image(systemName: SymbolAvailability.more)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(CircleIconButtonStyle())
        .fixedSize()
        .help("更多")
    }

    // MARK: - Battery

    private var batteryBlock: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.batteries, id: \.title) { battery in
                VStack(spacing: 4) {
                    EarbudArtwork(kind: battery.kind)
                    Text(battery.title)
                        .font(PanelFonts.micro)
                        .foregroundStyle(PanelPalette.secondaryText)
                    HStack(spacing: 4) {
                        Text(battery.value)
                            .font(PanelFonts.value)
                            .foregroundStyle(battery.level == nil || battery.isStale
                                             ? PanelPalette.secondaryText
                                             : PanelPalette.primaryText)
                        BatteryGlyph(level: battery.isStale ? nil : battery.level, charging: battery.charging)
                        if battery.isStale && battery.level != nil {
                            Image(systemName: SymbolAvailability.refresh)
                                .font(.system(size: 8))
                                .foregroundStyle(PanelPalette.warning)
                                .help("读数待刷新")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .help(battery.help ?? "")
            }
        }
        .frame(height: PanelMetrics.batteryBlockHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Noise control

    private var noiseCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: PanelMetrics.noiseCardSpacing) {
                HStack {
                    Text("噪声控制").font(PanelFonts.section).foregroundStyle(PanelPalette.secondaryText)
                    Spacer()
                    Text(snapshot.noiseCurrentText)
                        .font(PanelFonts.caption)
                        .foregroundStyle(PanelPalette.secondaryText)
                }

                HStack(spacing: 0) {
                    ForEach(snapshot.modeControls, id: \.id) { control in
                        modeButton(control)
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("降噪强度").font(PanelFonts.micro).foregroundStyle(PanelPalette.secondaryText)
                    levelSegments
                }
            }
        }
    }

    private func modeButton(_ control: PanelSnapshot.ModeControl) -> some View {
        Button {
            actions.onNoise(UInt32(control.value))
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(control.isSelected ? PanelPalette.accent : PanelPalette.quietFill)
                        .frame(width: PanelMetrics.modeIconSize, height: PanelMetrics.modeIconSize)
                    Image(systemName: control.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(control.isSelected ? Color.white : PanelPalette.primaryText)
                }
                .overlay {
                    if control.isSelected {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: PanelMetrics.modeIconSize - 5, height: PanelMetrics.modeIconSize - 5)
                    }
                }
                Text(control.title)
                    .font(PanelFonts.caption)
                    .foregroundStyle(control.isSelected ? PanelPalette.primaryText : PanelPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.modeTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle(cornerRadius: 12))
        .disabled(!snapshot.noiseEnabled)
        .help(control.help)
    }

    /// One continuous four-segment bar instead of scattered small buttons.
    private var levelSegments: some View {
        HStack(spacing: 0) {
            ForEach(Array(snapshot.levels.enumerated()), id: \.element.id) { index, level in
                Button {
                    actions.onNoise(UInt32(level.value))
                } label: {
                    Text(level.title)
                        .font(PanelFonts.caption)
                        .foregroundStyle(level.isSelected ? Color.white : PanelPalette.primaryText)
                        .frame(maxWidth: .infinity, minHeight: PanelMetrics.levelSegmentHeight)
                        .background(level.isSelected ? PanelPalette.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle(cornerRadius: 7))
                .disabled(!snapshot.levelsEnabled)
                .overlay(alignment: .leading) {
                    if index > 0 {
                        Rectangle()
                            .fill(PanelPalette.divider)
                            .frame(width: PanelMetrics.hairline)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelPalette.quietFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Sound

    private var audioCard: some View {
        PanelCard(padding: 0) {
            VStack(spacing: 0) {
                menuRow(snapshot.equalizerRow, action: actions.onEqualizerMenu)
                Rectangle()
                    .fill(PanelPalette.divider)
                    .frame(height: PanelMetrics.hairline)
                    .padding(.leading, PanelMetrics.innerPadding + 26)
                menuRow(snapshot.spatialRow, action: actions.onSpatialMenu)
            }
        }
    }

    private func menuRow(_ row: PanelSnapshot.MenuRow, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tintColor(row.tint).opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: row.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tintColor(row.tint))
                }
                Text(row.title)
                    .font(PanelFonts.body)
                    .foregroundStyle(PanelPalette.primaryText)
                Spacer(minLength: 8)
                Text(row.currentText)
                    .font(PanelFonts.body)
                    .foregroundStyle(PanelPalette.secondaryText)
                    .lineLimit(1)
                Image(systemName: SymbolAvailability.chevronDown)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PanelPalette.tertiaryText)
            }
            .padding(.horizontal, PanelMetrics.innerPadding)
            .frame(height: PanelMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle(cornerRadius: 10))
        .disabled(!row.enabled)
        .help(row.help)
        .accessibilityLabel("\(row.title)，\(row.currentText)")
    }

    private func tintColor(_ tint: PanelSnapshot.MenuRowTint) -> Color {
        switch tint {
        case .equalizer: return PanelPalette.equalizerTint
        case .spatial: return PanelPalette.spatialTint
        }
    }

    // MARK: - Devices

    private var deviceCard: some View {
        PanelCard(fill: PanelPalette.quietFill) {
            VStack(alignment: .leading, spacing: 6) {
                Text("双设备连接").font(PanelFonts.section).foregroundStyle(PanelPalette.secondaryText)
                ForEach(snapshot.devices, id: \.id) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(PanelPalette.secondaryText)
                        Text(device.name)
                            .font(PanelFonts.body)
                            .foregroundStyle(PanelPalette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Circle()
                            .fill(device.isConnected ? PanelPalette.connected : PanelPalette.disconnected)
                            .frame(width: 6, height: 6)
                        Text(device.stateText)
                            .font(PanelFonts.micro)
                            .foregroundStyle(PanelPalette.secondaryText)
                    }
                    .frame(height: PanelMetrics.deviceRowHeight)
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Text(snapshot.lastUpdateText)
                .font(PanelFonts.micro)
                .foregroundStyle(PanelPalette.tertiaryText)
            Spacer()
            Button {
                actions.onRefresh()
            } label: {
                Image(systemName: SymbolAvailability.refresh)
            }
            .buttonStyle(CircleIconButtonStyle())
            .disabled(snapshot.busy)
            .help("重新读取耳机状态")
        }
        .frame(height: PanelMetrics.footerHeight)
    }
}
