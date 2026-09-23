import Foundation

/// Immutable view state for the daily-use panel.
///
/// The manager rebuilds this after every received frame and reassigns the hosting controller's
/// `rootView`; the view holds no state and no property wrappers. Protocol detail (bitmaps,
/// command numbers, ACKs, source labels) is deliberately absent here — it lives in the CLI,
/// `--diagnostics` and the docs instead.
struct PanelSnapshot {
    struct Battery {
        var title: String
        var value: String
        var symbol: String
        var charging: Bool
        var isStale: Bool
    }

    /// A selectable control. `id` is a stable, unique key for `ForEach` — never a device name.
    struct Selectable {
        var id: String
        var value: Int
        var title: String
        var isSelected: Bool
    }

    struct InfoRow {
        var id: String
        var title: String
        var value: String
        var detail: String
    }

    var title: String
    var connectionText: String
    var connectionOK: Bool
    var lastUpdateText: String
    var batteries: [Battery]
    var caseHint: String?
    /// 关闭 / 通透 / 自适应通透.
    var primaryNoiseOptions: [Selectable]
    /// The four noise-cancellation levels, laid out in two columns.
    var levelOptions: [Selectable]
    var noiseCurrentText: String
    var noiseEnabled: Bool
    var noiseDisabledReason: String?
    /// Equalizer presets, names only.
    var eqOptions: [Selectable]
    var eqCurrentText: String
    /// Spatial audio modes, names only.
    var spatialOptions: [Selectable]
    var spatialCurrentText: String
    var audioEnabled: Bool
    var audioDisabledReason: String?
    /// One row per connected device.
    var info: [InfoRow]
    var statusLine: String
    var showSettingsButton: Bool
    var isBusy: Bool

    static func empty() -> PanelSnapshot {
        PanelSnapshot(
            title: "Enco X3",
            connectionText: "未连接",
            connectionOK: false,
            lastUpdateText: "尚无数据",
            batteries: [
                Battery(title: "左耳", value: "--", symbol: "headphones", charging: false, isStale: true),
                Battery(title: "右耳", value: "--", symbol: "headphones", charging: false, isStale: true),
                Battery(title: "充电盒", value: "--", symbol: "battery.100", charging: false, isStale: true),
            ],
            caseHint: nil,
            primaryNoiseOptions: [],
            levelOptions: [],
            noiseCurrentText: "尚未读到",
            noiseEnabled: false,
            noiseDisabledReason: "等待降噪读数",
            eqOptions: [],
            eqCurrentText: "未知",
            spatialOptions: [],
            spatialCurrentText: "未知",
            audioEnabled: false,
            audioDisabledReason: "等待读数",
            info: [],
            statusLine: "启动中…",
            showSettingsButton: false,
            isBusy: false
        )
    }
}

struct PanelActions {
    var onNoise: (UInt32) -> Void
    var onEqualizer: (Int) -> Void
    var onSpatial: (Int) -> Void
    var onRefresh: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
}
