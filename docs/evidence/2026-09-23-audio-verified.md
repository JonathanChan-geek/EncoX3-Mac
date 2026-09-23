# EQ 与空间音效实机验收

时间：2026-09-23 13:14–13:15（北京时间）。环境与只读证据相同。主控独占设备通道，运行已审查、签名的 Probe.app；菜单栏应用事先退出。

命令：`open -W -n "Enco Probe.app" --stdout .../cycle-audio-01.txt --stderr .../cycle-audio-01-errors.txt --args cycle-audio --journal .../audio-restore-01.json`。本测试只发送预先限定的三个设置命令，没有配对、固件或恢复出厂操作。

## 实测结果

| 项目 | 目标 | ACK status | 查询回读 | 结果 |
|---|---:|---:|---:|---|
| EQ id=0 | 0 | 0 | 0 | verified |
| EQ id=1 | 1 | 0 | 1 | verified |
| EQ id=2 | 2 | 0 | 2 | verified |
| EQ id=3 | 3 | 0 | 3 | verified |
| EQ id=7 | 7 | 0 | 7 | verified |
| EQ id=4 | 4 | 0 | 4 | verified |
| 空间 type=1 | 1 | 0 | 1 | verified |
| 空间 type=2 | 2 | 0 | 2 | verified |
| 空间 type=0 | 0 | 0 | 0 | verified |

请求与响应 sequence 匹配，覆盖 `0xFF → 0x00` 回绕。所有步第一次查询即精确读回。

## 恢复

捕获的原值：ANC `8`（关闭）、EQ `4`（自定义）、空间 `0`（关闭）。先写回三项，再独立查询全部三项及 EQ 列表，第一轮联合验证通过。`restoreVerified=true`。

自定义频率 `[62,250,1000,4000,8000,16000]` Hz、增益 `[-3,1,1,-2,2,2]` dB 保持不变。未写入自定义增益曲线。

## 解释限制

- EQ 0/1/2/3/7 的中文名称来自 X3 上游配置；id 4 的“自定义”来自设备回包。控制值已测，声学效果未测。
- 空间 0/1/2 名称依据型号配置。耳机 ACK/回读不能证明 macOS/Apple 头部追踪集成。
- 双设备能力仅只读，不借此测试发送连接/优先级命令。

## 本地原始证据

原始日志不入 Git：`evidence/local/cycle-audio-01.txt`、`audio-restore-01.json`、`audio-acceptance-build.txt`。

journal SHA-256：`01b7f2874a5ecd2791058833d62fde03cc294eb34add03861f19de22547461de`。
