import SwiftUI

/// Daily-use panel. Pure rendering of `PanelSnapshot`: no state, no property wrappers, no
/// observation macros. Every control is disabled unless the snapshot says it is usable, and the
/// snapshot's gates are the same ones the write paths enforce.
struct PanelView: View {
    let snapshot: PanelSnapshot
    let actions: PanelActions

    private let levelColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                batteryRow
                Divider()
                noiseSection
                Divider()
                audioSection
                if !snapshot.info.isEmpty {
                    Divider()
                    deviceSection
                }
                Divider()
                footer
            }
            .padding(14)
        }
        .frame(width: 360, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(snapshot.title).font(.headline)
                Circle()
                    .fill(snapshot.connectionOK ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(snapshot.connectionText).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if snapshot.isBusy {
                    Text("读取中…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(snapshot.lastUpdateText).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var batteryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ForEach(snapshot.batteries, id: \.title) { battery in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: battery.symbol).font(.caption)
                            Text(battery.title).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            Text(battery.value)
                                .font(.title3)
                                .foregroundStyle(battery.isStale ? Color.secondary : Color.primary)
                            if battery.charging {
                                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green)
                            }
                        }
                        if battery.isStale {
                            Text("待刷新").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                }
            }
            if let hint = snapshot.caseHint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var noiseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("降噪").font(.subheadline).bold()
                Spacer()
                Text(snapshot.noiseCurrentText).font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(snapshot.primaryNoiseOptions, id: \.id) { option in
                    Button(option.title) { actions.onNoise(UInt32(option.value)) }
                        .disabled(!snapshot.noiseEnabled)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(option.isSelected ? Color.accentColor : Color.secondary)
                }
            }

            if !snapshot.levelOptions.isEmpty {
                Text("降噪档位").font(.caption2).foregroundStyle(.secondary)
                LazyVGrid(columns: levelColumns, spacing: 6) {
                    ForEach(snapshot.levelOptions, id: \.id) { option in
                        Button(option.title) { actions.onNoise(UInt32(option.value)) }
                            .disabled(!snapshot.noiseEnabled)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .tint(option.isSelected ? Color.accentColor : Color.secondary)
                    }
                }
            }

            if let reason = snapshot.noiseDisabledReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("音效").font(.subheadline).bold()

            HStack {
                Menu("EQ：\(snapshot.eqCurrentText)") {
                    ForEach(snapshot.eqOptions, id: \.id) { option in
                        Button(option.title) { actions.onEqualizer(option.value) }
                    }
                }
                .disabled(!snapshot.audioEnabled)
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Menu("空间音效：\(snapshot.spatialCurrentText)") {
                    ForEach(snapshot.spatialOptions, id: \.id) { option in
                        Button(option.title) { actions.onSpatial(option.value) }
                    }
                }
                .disabled(!snapshot.audioEnabled)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let reason = snapshot.audioDisabledReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            Text("耳机自身音效，不等同 Apple 空间音频。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已连接设备").font(.subheadline).bold()
            ForEach(snapshot.info, id: \.id) { row in
                HStack {
                    Text(row.value).font(.caption)
                    Spacer()
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.statusLine.isEmpty {
                Text(snapshot.statusLine).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("重新读取") { actions.onRefresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if snapshot.showSettingsButton {
                    Button("打开系统设置") { actions.onOpenSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                Button("退出") { actions.onQuit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
