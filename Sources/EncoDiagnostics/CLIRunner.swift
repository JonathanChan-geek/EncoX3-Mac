import Foundation

/// Command dispatch shared by `encoctl` and by the menu bar app's command-line modes, so the
/// probe and the write test behave identically however they are launched.
public enum CLIRunner {
    public static let usage = """
    encoctl — OPPO Enco X3 诊断工具（只读为主）

    用法
      encoctl inspect
          枚举已配对/已连接设备与目标的缓存 SDP 记录。只读：不开通道、不写设备。
      encoctl probe [--seconds N]
          打开 vendor RFCOMM 控制通道，被动收 2s，发一次 capability 查询，再逐项发一轮只读
          查询，其余时间收包。N 取 3…120，默认 20。结束时只关闭本应用的控制通道。
      encoctl cycle-audio [--journal /绝对路径.json]
          写测试：读取 cap/PID/ANC/EQ/空间/EQ列表，先把原始值写入恢复日志，然后按
          EQ id [0,1,2,3,7,4]、空间 [1,2,0] 依次设置并逐项回读，最后逐一恢复原值并复核
          EQ 曲线。只发送 0x0404/0x0406/0x0422，不写自定义 EQ 曲线。
          ⚠ 会修改耳机 EQ/空间/降噪设置（可恢复），由人工确认后运行。
      encoctl cycle-audio --listen-spatial [--journal /绝对路径.json]
          用户参与的空间听感测试：固定/跟随各20秒，系统人声提示，随后恢复全部原值。
          只在默认输出为 Enco X3 时播放，不更改音频输出或系统音量；原始通知写到 stdout。
      encoctl cycle-anc [--journal /绝对路径.json]
          写测试：读取 PID/ANC/电量，先把原始 ANC 位图写入恢复日志，然后按
          0x08/0x100/0x80/0x10/0x20/0x40/0x200 依次设置并逐项回读，最后按捕获位图恢复。
          任何失败立即停止并恢复；SIGINT/SIGTERM 只触发恢复，不提前退出。
          ⚠ 会修改耳机降噪设置（可恢复），由人工确认后运行。

    安全
      只连接已在系统中连接的设备；不配对、不断开、不改系统项。
      仅 cycle-anc / cycle-audio 会写入；允许 0x0404 降噪、0x0406 EQ 预设、0x0422 空间。
    """

    /// Each command's own exit code is returned unchanged.
    public static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "inspect":
            return InspectCommand.run(arguments: rest)
        case "probe":
            return ProbeCommand.run(arguments: rest)
        case "cycle-anc":
            return CycleAncCommand.run(arguments: rest)
        case "cycle-audio":
            return CycleAudioCommand.run(arguments: rest)
        case "help", "-h", "--help":
            print(usage)
            return 0
        default:
            print("unknown command '\(command)'")
            print("")
            print(usage)
            return 2
        }
    }

    /// True when the argument list names one of the diagnostic commands.
    public static func handles(_ arguments: [String]) -> Bool {
        guard let command = arguments.first else { return false }
        return ["inspect", "probe", "cycle-anc", "cycle-audio", "help", "-h", "--help"].contains(command)
    }

    /// Double-clicked from Finder (no arguments): run the read-only probe and keep the output
    /// in a log file, since a bundled launch has no visible stdout.
    public static func runBundledProbe() -> Int32 {
        let log = bundledLogURL()
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = freopen(log.path, "a", stdout)
        print("=== bundled launch \(ISO8601DateFormatter().string(from: Date())) ===")
        print("log: \(log.path)")
        print("只读探测 20 秒；写测试见 cycle-anc / cycle-audio（见 README）")
        return ProbeCommand.run(arguments: ["--seconds", "20"])
    }

    public static func bundledLogURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return base.appendingPathComponent("EncoX3", isDirectory: true)
            .appendingPathComponent("probe-\(stamp).log")
    }
}
