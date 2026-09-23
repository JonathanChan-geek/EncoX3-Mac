import AppKit
import EncoDiagnostics

/// Menu bar entry point.
///
/// With a diagnostic command as the first argument it behaves exactly like `encoctl`
/// (`EncoMenu probe`, `EncoMenu cycle-audio`, …) so both bundles can run the same logic.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnosticsEnabled: Bool
    private let appearance: PanelAppearance
    private var manager: MenuManager?

    init(appearance: PanelAppearance, diagnosticsEnabled: Bool) {
        self.appearance = appearance
        self.diagnosticsEnabled = diagnosticsEnabled
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = MenuManager(appearance: appearance, diagnosticsEnabled: diagnosticsEnabled)
        self.manager = manager
        manager.start()
    }

    /// Double-clicking the app again (or `open` on a running instance) brings the panel up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manager?.showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.shutdown()
        manager = nil
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

if CLIRunner.handles(arguments) {
    exit(CLIRunner.run(arguments: arguments))
}

// Both opt-in flags are accepted for compatibility only: the noise-reduction values, the six
// equalizer presets and the three spatial modes were each accepted by the device with an exact
// readback, so they are available by default. The gates that remain are the live ones: channel
// open, verified model, fresh readings and one write at a time.
let knownFlags: Set<String> = ["--enable-verified-anc", "--enable-audio", "--diagnostics"]
let unknown = arguments.filter { argument in
    !knownFlags.contains(argument) && !argument.hasPrefix("--appearance")
}
if !unknown.isEmpty {
    FileHandle.standardError.write(Data("""
    未知参数: \(unknown.joined(separator: " "))
    开关: --diagnostics（最小状态日志到 stderr）
          --appearance=light|dark（仅本应用的界面临时预览，不改系统外观）
    兼容（已无效果）: --enable-verified-anc、--enable-audio —— 降噪/EQ/空间均默认可用
    命令行模式: EncoMenu probe|cycle-anc|cycle-audio|inspect|help

    """.utf8))
    exit(2)
}

/// Visual QA switch: applies to this app only, for screenshotting both appearances.
/// Nothing is written to the system defaults.
func resolvedAppearance(from arguments: [String]) -> PanelAppearance {
    var requested: String?
    for argument in arguments where argument.hasPrefix("--appearance") {
        let value: String
        if argument == "--appearance" {
            value = ""
        } else if argument.hasPrefix("--appearance=") {
            value = String(argument.dropFirst("--appearance=".count))
        } else {
            FileHandle.standardError.write(Data("外观参数格式错误: \(argument)（应为 --appearance=light 或 --appearance=dark）\n".utf8))
            exit(2)
        }
        guard value == "light" || value == "dark" else {
            FileHandle.standardError.write(Data("外观参数只接受 light 或 dark，收到 '\(value)'\n".utf8))
            exit(2)
        }
        if let previous = requested, previous != value {
            FileHandle.standardError.write(Data("外观参数冲突: --appearance=\(previous) 与 --appearance=\(value)\n".utf8))
            exit(2)
        }
        requested = value
    }
    guard let requested, let appearance = PanelAppearance(flag: requested) else { return .system }
    return appearance
}

let appearance = resolvedAppearance(from: arguments)

let diagnosticsEnabled = arguments.contains("--diagnostics")
let app = NSApplication.shared
let delegate = AppDelegate(appearance: appearance, diagnosticsEnabled: diagnosticsEnabled)
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Set the application-level appearance as well; the manager also pushes it to the popover and
// the hosting view, which is where a menu bar popover actually picks it up.
if let nsAppearance = appearance.nsAppearance {
    app.appearance = nsAppearance
}
app.run()
