# X3 只读初查（SDP 缓存与 vendor 服务）

时间：2026-09-23（本机 macOS 27.2，Apple Silicon）。地址一律掩码为 `40:72:18:XX:XX:XX`。

命令：`xcrun swift Tools/inspect.swift`（原始输出 `evidence/local/inspect.txt`），以及
`xcrun swift Tools/inspect.swift --sdp`（`evidence/local/inspect-sdp.txt`）。

- 配对设备 1 台，名称 `OPPO Enco X3`，`isConnected()==true`；探针不连接、不配对、不发包。
- 缓存 SDP 记录 14 条；强制 SDP query（异步，10s 上限）后仍是同样 14 条，逐行 diff 无差异，只有
  新增的 `sdpQueryComplete status: kIOReturnSuccess` 三行 → 缓存可信。
- vendor UUID `0000079A-D102-11E1-9B23-00025B00A5A5` 存在：记录 4，`serviceName=ELNK`，
  `getRFCOMMChannelID` 成功，**channel 15**（记录 4 的 `ProtocolDescriptorList` 也写作 0x0003/15）。
- 另一条相关记录 6：`serviceName=enco rcord`，UUID `0000079B-D102-11E1-9B23-00025B00A5A5`，channel 24。
- 其余为 HFP(TOTA ch12)、A2DP/AVRCP(L2CAP 23)、HID 等；channel 字段为 1 的几条属系统侧记录。
- 未验证项：未打开任何 RFCOMM 通道，未发送帧，因此 ELNK 是否承载控制协议、channel 15 是否可
  独占打开，本轮均无实测结论；电量/ANC 等回包格式亦未实测。

结论：vendor 控制服务在 SDP 中可达，controller 侧 channel = 15，供后续只读 probe 动态解析使用。
