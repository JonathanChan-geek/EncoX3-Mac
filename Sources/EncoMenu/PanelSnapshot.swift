import Foundation

/// Immutable view state for the panel.
///
/// The manager rebuilds this after every received frame and reassigns the hosting controller's
/// `rootView`; the view holds no state and no property wrappers. Protocol detail (bitmaps, command
/// numbers, ACKs, source labels) is deliberately absent — it lives in the CLI, `--diagnostics` and
/// the docs.
struct PanelSnapshot {
    struct Battery {
        var title: String
        var value: String
        var kind: ArtworkKind
        /// nil when the device did not report a usable level: drawn as `--`, never as 0%.
        var level: Int?
        var charging: Bool
        var isStale: Bool
        var help: String?
    }

    /// A selectable control. `id` is a stable unique key for `ForEach` — never a device name.
    struct Selectable {
        var id: String
        var value: Int
        var title: String
        var isSelected: Bool
    }

    /// One of the four noise-control mode buttons.
    struct ModeControl {
        var id: String
        var value: Int
        var title: String
        var symbol: String
        var isSelected: Bool
        var help: String
    }

    /// A row that opens a menu.
    struct MenuRow {
        var id: String
        var title: String
        var symbol: String
        var tint: MenuRowTint
        var currentText: String
        var options: [Selectable]
        var enabled: Bool
        var help: String
    }

    enum MenuRowTint {
        case equalizer
        case spatial
    }

    struct DeviceRow {
        var id: String
        var name: String
        var symbol: String
        var stateText: String
        var isConnected: Bool
    }

    var brand: String
    var title: String
    var connectionText: String
    var connectionOK: Bool

    var batteries: [Battery]

    var modeControls: [ModeControl]
    var noiseCurrentText: String
    var noiseEnabled: Bool
    var noiseDisabledReason: String?
    var levels: [Selectable]
    var levelsEnabled: Bool

    var equalizerRow: MenuRow
    var spatialRow: MenuRow
    var audioEnabled: Bool
    var audioDisabledReason: String?

    var devices: [DeviceRow]

    var lastUpdateText: String
    /// Only real problems: not connected, read failure, write timeout. Shown as a short orange line.
    var errorLine: String?
    var busy: Bool
    var showSettingsButton: Bool
    var connectionNoticesEnabled: Bool = true

    static func empty() -> PanelSnapshot {
        PanelSnapshot(
            brand: "OPPO",
            title: "Enco X3",
            connectionText: "未连接",
            connectionOK: false,
            batteries: [
                Battery(title: "左耳", value: "--", kind: .earbudLeft, level: nil, charging: false, isStale: true, help: nil),
                Battery(title: "右耳", value: "--", kind: .earbudRight, level: nil, charging: false, isStale: true, help: nil),
                Battery(title: "充电盒", value: "--", kind: .chargingCase, level: nil, charging: false, isStale: true, help: "盒盖打开且耳机入盒时可读取"),
            ],
            modeControls: [],
            noiseCurrentText: "尚未读到",
            noiseEnabled: false,
            noiseDisabledReason: nil,
            levels: [],
            levelsEnabled: false,
            equalizerRow: MenuRow(
                id: "eq", title: "均衡器", symbol: SymbolAvailability.equalizer, tint: .equalizer,
                currentText: "未知", options: [], enabled: false, help: "耳机自身的均衡器预设"
            ),
            spatialRow: MenuRow(
                id: "spatial", title: "空间音效", symbol: SymbolAvailability.spatial, tint: .spatial,
                currentText: "未知", options: [], enabled: false,
                help: "耳机自身的空间音效模式，不等同 Apple 空间音频"
            ),
            audioEnabled: false,
            audioDisabledReason: nil,
            devices: [],
            lastUpdateText: "尚无数据",
            errorLine: nil,
            busy: false,
            showSettingsButton: false
        )
    }
}

/// Actions the view can trigger. `onAbout` shows the about alert; it never writes to the device.
struct PanelActions {
    var onNoise: (UInt32) -> Void
    /// Opens the AppKit menu for the row; the selection itself is forwarded by the manager.
    var onEqualizerMenu: () -> Void
    var onSpatialMenu: () -> Void
    var onRefresh: () -> Void
    var onAbout: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onPreviewConnectionNotice: () -> Void = {}
    var onToggleConnectionNotice: () -> Void = {}
}
