import AppKit
import EncoDiagnostics

/// Menu bar entry point.
///
/// With a diagnostic command as the first argument it behaves exactly like `encoctl`
/// (`EncoMenu probe`, `EncoMenu cycle-audio`, …) so both bundles can run the same logic.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnosticsEnabled: Bool
    private var manager: MenuManager?

    init(diagnosticsEnabled: Bool) {
        self.diagnosticsEnabled = diagnosticsEnabled
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = MenuManager(diagnosticsEnabled: diagnosticsEnabled)
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
let unknown = arguments.filter { !knownFlags.contains($0) }
if !unknown.isEmpty {
    FileHandle.standardError.write(Data("""
    未知参数: \(unknown.joined(separator: " "))
    开关: --diagnostics（最小状态日志到 stderr）
    兼容（已无效果）: --enable-verified-anc、--enable-audio —— 降噪/EQ/空间均默认可用
    命令行模式: EncoMenu probe|cycle-anc|cycle-audio|inspect|help

    """.utf8))
    exit(2)
}

let diagnosticsEnabled = arguments.contains("--diagnostics")
let app = NSApplication.shared
let delegate = AppDelegate(diagnosticsEnabled: diagnosticsEnabled)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
