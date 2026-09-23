import AppKit
import SwiftUI

struct ExperienceSnapshot {
    var showPercentage: Bool
    var lowAlerts: Bool
    var chargingAlerts: Bool
    var shortcuts: Bool
    var scenes: [String]
    var canSave: Bool
    var canApply: Bool
    var outputDevices: [AudioOutput.Device]
    var currentOutput: UInt32?
    var recoveryNeeded: Bool
    var message: String?
}

enum ExperienceAction {
    case percentage(Bool), low(Bool), charging(Bool), shortcuts(Bool)
    case save(Int), apply(Int), output(String), recover, panel
}

@MainActor
final class ExperienceWindow {
    private var window: NSWindow?
    private var host: NSHostingController<ExperienceView>?
    var visible: Bool { window?.isVisible ?? false }
    func show(_ snapshot: ExperienceSnapshot, action: @escaping (ExperienceAction) -> Void) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 650),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Enco X3 · 日常体验"
            w.isReleasedWhenClosed = false
            w.center()
            let h = NSHostingController(rootView: ExperienceView(snapshot: snapshot, action: action))
            w.contentViewController = h
            window = w; host = h
        }
        update(snapshot, action: action)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func close() { window?.close() }
    func update(_ snapshot: ExperienceSnapshot, action: @escaping (ExperienceAction) -> Void) {
        host?.rootView = ExperienceView(snapshot: snapshot, action: action)
    }
}

private struct ExperienceView: View {
    let snapshot: ExperienceSnapshot
    let action: (ExperienceAction) -> Void
    private let names = ["专注", "通勤", "观影"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "airpodspro").font(.system(size: 30)).foregroundStyle(PanelPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("让耳机顺手一点").font(.system(size: 21, weight: .semibold))
                        Text("电量提醒、快捷操作与音频输出").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("控制面板") { action(.panel) }.font(.system(size: 11))
                }.padding(.vertical, 4)
                card("电量") {
                    settingToggle("菜单栏显示耳机电量", value: snapshot.showPercentage) { action(.percentage($0)) }
                    settingToggle("低电量提醒 · 20% / 10%", value: snapshot.lowAlerts) { action(.low($0)) }
                    settingToggle("充电状态变化时提醒", value: snapshot.chargingAlerts) { action(.charging($0)) }
                }
                card("快捷键") {
                    settingToggle("启用全局快捷键", value: snapshot.shortcuts) { action(.shortcuts($0)) }
                    Text("⌃⌥⌘ E  打开面板     ⌃⌥⌘ N  切换降噪 / 通透\n⌃⌥⌘ 1 / 2 / 3  应用下方三个场景")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
                card("我的场景") {
                    Text("调整主面板的降噪、均衡器和空间音效后，保存到任一场景。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(0..<3) { index in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(names[index]).font(.system(size: 12, weight: .medium))
                                Text(snapshot.scenes[index]).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button("保存当前") { action(.save(index)) }.disabled(!snapshot.canSave)
                            Button("应用") { action(.apply(index)) }
                                .disabled(!snapshot.canApply || snapshot.scenes[index] == "尚未保存")
                        }
                        if index < 2 { Divider() }
                    }
                    if snapshot.recoveryNeeded {
                        Button("恢复上次未完成操作前的设置") { action(.recover) }.disabled(!snapshot.canSave)
                    }
                }
                card("Mac 音频输出") {
                    Menu {
                        ForEach(snapshot.outputDevices) { device in
                            Button((device.id == snapshot.currentOutput ? "✓ " : "") + device.name) { action(.output(device.uid)) }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "speaker.wave.2")
                            Text(snapshot.outputDevices.first { $0.id == snapshot.currentOutput }?.name ?? "未读取到输出设备")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                        }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    Text("选择 Mac 当前的播放设备。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let message = snapshot.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(22)
        }
        .frame(width: 450, height: 650)
        .background(PanelPalette.window)
    }
    private func settingToggle(_ title: String, value: Bool, changed: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: Binding(get: { value }, set: changed)).labelsHidden()
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }.font(.system(size: 12)).toggleStyle(.switch)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelPalette.card, in: RoundedRectangle(cornerRadius: 15))
    }
}
