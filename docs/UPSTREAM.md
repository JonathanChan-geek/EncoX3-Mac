# 开源来源与许可

核对时间：2026-09-23。项目按 GPL-3.0-or-later 分发。

- https://github.com/anikket-b/Realme-TWS-Mac-Controller @ `2c1e7d8aaba1441d3e11c06624df840f8d17181b`
- https://github.com/Zhaoyi-ya/OppoPodsManager @ `f272e9e95bb20bfb8e317af06be776c26f1eb077`
- https://github.com/t3rhetto/OPPOPodsManagerForMac @ `050c1beb2ac318986a26273eb49a47cc9ebffe83`
- https://github.com/AasheeshLikePanner/cracked-oneplus-buds @ `632076540684a2127ef701db9e3c9a309ffac8fb`

Swift RFCOMM 结构参考 Realme 项目（MIT，版权声明保存在 LICENSES/Realme-MIT.txt）；协议和 X3 型号能力依据 OppoPodsManager（GPL-3.0-or-later，版权见 LICENSE）。Mac C# 项目仅作对照，不采用其 POSIX 传输。cracked-oneplus-buds 未发现许可证，仅阅读其协议描述，不复制其代码。

0.4 的佩戴通知结构参考固定版本 OppoPodsManager 的 `Services/PodManager.Parsing.cs / ParseWearingData`，Swift 解析器仅标注本机动作验证过的 05/07，其余值保留未知；沿用 GPL-3.0-or-later 许可。电量提醒策略、场景执行与恢复、CoreAudio 路由、Carbon 热键及日常体验窗口为本项目实现。
