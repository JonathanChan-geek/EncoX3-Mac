# Enco X3 for Mac

独立的原生 macOS 菜单栏应用，使用 Swift/SwiftUI、AppKit 和 IOBluetooth RFCOMM 控制 **OPPO Enco X3（PID 067410）**。不依赖 Electron、Python、后台服务器或手机中转。

## 已完成并实机验证

| 功能 | 当前支持 |
|---|---|
| 左耳、右耳、充电盒电量 | 百分比与充电标志；未上报显示 `--` |
| 降噪与通透 | 关闭、固定通透、自适应通透、智能/深度/中度/轻度降噪 |
| EQ | 至臻原音、高清解析、纯享人声、澎湃低音、丹拿特调、自定义预设切换 |
| 耳机空间音效 | 关闭、固定、跟随 |
| 双设备 | 读取耳机报告的连接设备名称及状态；不改变连接或优先级 |
| 状态同步 | 设备通知 + 定期查询、打开面板刷新、失联重试、唤醒后重新查询 |

所有控制默认开放，但只对型号确认、通道正常且相关读数新鲜的设备启用。成功须收到成功 ACK **并精确回读目标值**；超时、拒绝、归一化均不冒充成功。

2026-09-23 本机实测：7 种降噪状态、6 个 EQ 预设、3 种空间模式逐项通过；测试后恢复 **降噪关闭 / EQ 自定义 / 空间关闭**，自定义 EQ 频率和增益未改变。详情见 [验收记录](docs/evidence/2026-09-23-audio-verified.md) 与 [降噪记录](docs/evidence/2026-09-23-anc-verified.md)。这些是协议与状态验证，没有进行声学测量；模式名称来自 X3 型号配置，自定义名称来自设备回包。

## 界面

0.2 版参考 Apple AirPods 与 HeyMelody 的信息层级重新设计：耳机/盒子电量展示、四模式图标选择、降噪强度分段控件、整行音效菜单及紧凑双设备列表。界面跟随系统深浅外观。设计研究和来源见 [视觉设计记录](docs/design/2026-09-23-ui-redesign.md)。

## 使用

1. 先在 macOS 蓝牙设置中连接 OPPO Enco X3。
2. 打开 `Enco X3.app`，点击菜单栏耳机图标查看状态和控制。
3. 若系统询问蓝牙权限，允许应用访问；若首次没有数据，可在“系统设置 → 隐私与安全性 → 蓝牙”检查权限。

充电盒休眠时可能不报告电量。本次只开盖仍无盒电量，**一只耳机入盒并保持开盖**后成功读到。界面不会拿历史盒电量冒充实时值。

应用只打开自己的控制通道，不主动配对、取消配对或断开系统音频连接；不恢复出厂、不更新固件。使用菜单栏控制会保留你主动选择的设置；只有诊断轮转测试会自动恢复测试前设置。

## 构建与安装

本机验收环境：Apple Silicon、macOS 27.2 (26B5091g)、Swift 6.4 / Command Line Tools。最低部署目标 macOS 13，**其他系统和固件尚未实机验证**。

```bash
swift run EncoCoreChecks   # 独立的离线协议/恢复逻辑校验
./build.sh                # Release 构建、打包、ad-hoc 签名与校验
./scripts/install.sh      # 安装到 ~/Applications
open "$HOME/Applications/Enco X3.app"
```

产物为 `dist/Enco X3.app` 和 `dist/Enco Probe.app`。仅本地 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证。本机只有 CLT、缺少 XCTest，因此采用无依赖 executable checks；不声称 `swift test` 已通过。

可选 `--diagnostics` 在 stderr 输出最小连接/状态日志。旧参数 `--enable-verified-anc`、`--enable-audio` 仅兼容保留，已不影响功能开关。应用与 Probe 不宜同时占用控制通道。

## 诊断工具

```bash
# 只读：配对设备和缓存 SDP 枚举
"dist/Enco Probe.app/Contents/MacOS/encoctl" inspect

# 只读：推荐通过含蓝牙权限说明的 app 启动
open -W -n "dist/Enco Probe.app" --stdout /tmp/enco-probe.txt \
  --stderr /tmp/enco-probe-errors.txt --args probe --seconds 20

# 写测试：先退出菜单栏应用，保存原值、逐项切换、最后恢复并核验
open -W -n "dist/Enco Probe.app" --stdout /tmp/enco-anc.txt \
  --args cycle-anc --journal /tmp/enco-anc-restore.json
open -W -n "dist/Enco Probe.app" --stdout /tmp/enco-audio.txt \
  --args cycle-audio --journal /tmp/enco-audio-restore.json
```

`open` 自身的退出码不代表全部测试通过；核对输出以及 journal 的 `restoreVerified`。

`cycle-anc` 依次验证 `[8,256,128,16,32,64,512]`。`cycle-audio` 验证 EQ `[0,1,2,3,7,4]` 和空间 `[1,2,0]`；仅切换预设，不写自定义 EQ 曲线。任何一步失败即停止轮转并恢复。原值在首个写命令前落盘，SIGINT/SIGTERM 转入恢复；断电、强杀或连接丢失无法保证自动恢复，应保留日志核对。音频恢复后重新独立查询 ANC/EQ/空间/曲线，最多再尝试一轮恢复，不拿缓存充当验证；不覆盖未完成的音频恢复日志。

只允许三个设置命令：`0x0404` 降噪、`0x0406` EQ 预设、`0x0422` 空间音效。禁止未经确认的写命令、固件、配对和重置操作。原始日志可能包含设备标识，放在 Git 忽略的 `evidence/local/`；仅脱敏结论提交入库。

## 能力边界

- 没有 iCloud 配对、Apple 查找网络、Apple 设备自动切换或系统 AirPods 专属界面。
- “跟随”是耳机自身空间模式，不代表已接入 macOS/Apple 动态头部追踪。
- 双设备仅显示状态；本机能力回包没有对应的优先级/切换指令支持，因此不提供控制。
- EQ 内置名称依据上游 X3 配置；本机只返回自定义曲线，没有测量各预设声学效果。
- 断连、系统睡眠和跨设备抢占的长期稳定性还需日常使用检验；已实现重试与过期数据处理，不能将实现视为长期实测。

## 源码与许可

- `Sources/EncoCore`：帧、解析、型号、状态及恢复验证。
- `Sources/EncoBluetooth`：原生 SDP/RFCOMM 与串行事务。
- `Sources/EncoDiagnostics` / `Sources/encoctl`：只读诊断及可恢复测试。
- `Sources/EncoMenu`：原生菜单栏和 SwiftUI 面板。
- `Tests/EncoCoreTests`：离线校验；`docs/evidence`：脱敏证据。

按 **GPL-3.0-or-later** 分发。固定上游版本与使用范围见 [UPSTREAM](docs/UPSTREAM.md)，版权见 `LICENSE` 和 `LICENSES/`；许可证同时附在 App 包内。
