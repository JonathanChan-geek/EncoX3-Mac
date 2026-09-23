# 只读协议帧与离线校验（阶段记录）

后续解析和控制已扩展，当前契约以 `docs/PROTOCOL.md` 为准。下面保留早期阶段边界，电量格式已按实测更正。

## 帧格式（已实现，单字节 len）

`AA len 00 00 cmdLo cmdHi seq payLenLo payloadLenHi payload`，`len = 7 + payload.count`，
cmd 与 payloadLen 均为小端；总长 `len + 2` 上限 257（`len` 只有一字节）。
`seq` 请求默认 0xF0，每次发送递增。依据 OppoPodsManager `Transport/SppFrameCodec.cs`
（GPL-3.0-or-later，见 docs/UPSTREAM.md）。

两条长度字段必须严格一致（`len == 7 + payLen`）：不一致即拒帧并按字节重同步，不做截断或补零。
流式解析器支持拆包、粘包、前导垃圾、坏长度恢复；收到完整 9 字节头即可判定长度矛盾，避免坏
大 len 长时间阻塞后续正确帧。若将来实测到带 padding 的真实特殊帧，再以证据单独建规则。

## 本阶段允许发送的命令（均为只读查询）

- `0x0100` capability（“hello”线上字节 `00 01`，即 capability query；**不发任何认证帧**）
- `0x0103` PID、`0x0106` 电量、`0x010C` 降噪（payload `01 01`）、`0x0105` 版本、
  `0x010F` EQ、`0x012A` 空间音效、`0x0112` 多设备

clamp：`--seconds` 只接受 3…120 的有限数，未知参数直接报错退出。probe 只发一轮查询，其余时间
收包。不写任何设置、不配对、不 openConnection/closeConnection，只 closeChannel 自身通道。

## 解析规则

- **先存原始包**：每个响应命令的 payload 原样保存在 `rawResponses`，再尝试解析。
- **status 非 0 即失败**：记录到 `statusFailures`，绝不写进状态；后续成功响应才清除该失败记录。
- **新建时间按字段隔离**：battery / ANC / PID / 版本 / capability 各自有更新时间；EQ 回包或失败
  回包不刷新任何字段的时间。
- 电量：`0x8106 [status,count,id,raw,...]`；通知 `0x0204` 子类型 `0x01`
  `[count,id,raw...]`（raw 高位置充电），条数不足整帧拒绝，不做部分更新。上报 0 或 >100 视为
  未知（不是 0%），原始值保留在 `reportedLevel`。
- 降噪：`0x810C [status,01,01,bitmapLE...]`、通知 `0x0204 [03,01,01,bitmapLE...]`；只输出原始
  位图，不套用 realme/OPPO 模式枚举。
- PID：`0x8103 [status,id0,id1,id2]` 小端 → 6 位十六进制（`10 74 06` → `067410`）。
- 未匹配已知布局的 payload 进 `unparsedPayloads` 原样保留；EQ/多设备/空间音效本轮仅存 raw。

## 离线校验命令（本机无 XCTest）

本机只有 Command Line Tools、未安装 Xcode，`XCTest.framework` 不存在，`swift test` 无法编译。
因此改为无依赖 executable target `EncoCoreChecks`（源码 `Tests/EncoCoreTests/`）：

```
swift build
swift run EncoCoreChecks      # 失败 exit 1，打印汇总
```

这不是 `swift test` 成功，只是本机可执行的等价离线校验；日志见
`evidence/local/enco-core-checks.txt`。实机只读抓包：`swift run encoctl probe --seconds 20`
（输出 `evidence/local/probe.txt`）、`swift run encoctl inspect`。
