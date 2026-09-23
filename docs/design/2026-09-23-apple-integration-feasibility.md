# Enco X3 与 Apple 耳机体验的可行性调研

调研日期：2026-09-23。范围为资料、现有源码和既有实机证据复核；本次没有操作配对、固件、耳机设置或广播模拟。以下“可行性”是工程判断，不是已实现功能清单。

后续实现与听感结果已更新至 [0.3.0 验收记录](../evidence/2026-09-23-v030-experience.md)。以下保留调研时的判断，不将调研计划冒充当时已完成。

## 结论

Enco X3 确有运动传感器和双设备连接基础。不能因为没有 Apple 芯片，就判定所有类似体验都做不了；也不能因为有相同传感器，就认定现有固件会提供 Apple 所需的协议和密钥。

当前可优先推进 Mac 自有连接/电量浮层，以及耳机内置头部追踪的效果验证。智能切换需要验证双设备音频竞争规则。系统 AirPods 身份、iCloud 一次配对全设备可用、离线 Find My 网络，均未找到可直接通过当前 Mac App 给原厂 X3 开启的路径。

另有重要新情况：Apple 已提供第三方配件邻近配对、AudioAccessoryKit 自动切换，以及新的头部追踪接口。它们使部分官方接入成为可能，但有平台、地区、配套 App、配件注册或数据接口前提，不能直接套到本 macOS 项目。

## 硬件和本机证据

- [52audio 原创拆解](https://www.52audio.com/archives/217819.html)在 Enco X3 样品中识别到 BES2700ZP 主控及 ST LSM6DSV16BX 六轴 IMU，并展示相关电路照片。这是对该拆解样品的证据，不是本机拆机鉴定；不能由此推断所有硬件批次相同。
- [ST 官方器件资料](https://www.st.com/en/mems-and-sensors/lsm6dsv16bx.html)确认该器件为六轴惯性传感器。芯片能测量运动，不代表主机能经蓝牙读取这些数据。
- [本项目已有实测](../evidence/2026-09-23-audio-verified.md)确认空间模式 0/1/2 均成功 ACK 并精确回读，测试后恢复 0；没有声学测试，也未取得连续姿态数据。
- 当前源码只解析空间模式值与双设备列表，没有头部姿态、IMU 流或 Apple AAP/MagicPairing 实现。读取两个连接设备不能单独证明我们能控制音源抢占。

## “洛达能做”说明了什么

应区分芯片、整机方案和固件版本。Airoha 的[芯片产品说明](https://www.airoha.com/products/p/HanExuKmg0K35S1w)不能证明每款采用该芯片的耳机都具有相同 Apple 协议兼容性。X3 拆解中的主控也不是该洛达平台，不能移植其成品固件当作通用插件。

[AirReps 社区目录](https://airpodsreplicas.com/version-info/pro)把不同洛达、慧联方案的头部追踪、多点连接和 iCloud Connect 分开列示，有些标注受固件影响。该目录可以作为找具体样机验证的线索；其中部分条目引用商家宣传，不能当成经独立协议验证的事实，更不能概括为“所有洛达完整支持 Apple 生态”。本次未测试任何仿制耳机。

从公开协议研究可以确认的，是这些能力在不同协议层实现：

1. [Proximity 广播逆向记录](https://github.com/fischejo/airpods-notify/blob/master/doc/proximity_protocol.md)及研究者的[邻近配对实验](https://ecto-1a.github.io/AppleJuice/)表明，特定 BLE 广播可以触发部分 Apple 配对界面。界面出现不证明音频连接、密钥同步或后续控制成功，历史 PoC 也不证明当前所有系统版本行为相同。
2. [MagicPairing 研究论文](https://arxiv.org/abs/2005.07255)说明一次配对后在同账户设备间使用，涉及 Bluetooth 之上的认证和密钥派生协议；并非仅修改蓝牙名称或型号字段。
3. [LibrePods](https://github.com/librepods-org/librepods)从主机侧实现 AirPods 私有控制协议，证明高级功能并非全都只能由 Apple 主机访问。但该方向是“非 Apple 主机控制本来就会说 Apple 协议的耳机”，不能据此推导“原厂 OPPO 固件会回应 Apple 协议”。该项目也明确区分已实现功能和头部追踪渲染、Find My 等未完成能力。

## 逐项判断

| 用户体验 | 原厂 X3 + 当前 Mac App 的判断 | 真正缺少的条件 |
|---|---|---|
| 连接后自动显示耳机、电量浮层 | 高可行性，AppKit/SwiftUI 自有窗口即可实现 | 持续可靠的连接事件与电量；真正“开盖即弹”还需确认休眠/未连接时可观察的开盖信号 |
| Apple 系统自身的 AirPods 弹窗及设置页 | 未找到直接 Mac 侧接入原厂 X3 的路径 | 设备身份、广播与系统匹配的完整协议；单独模拟提示不等于完成集成 |
| 根据播放/通话智能切换 | 有条件可行，先做 Mac 输出路由与双连接场景验证 | 手机侧音频状态、耳机音源仲裁/释放机制，不能只切 Mac 默认输出就宣称跨设备无缝切换 |
| X3 自身的头部追踪 | 有硬件及模式控制基础，优先验证 | 转头时是否真的维持声源方向、是否耳机独立处理、延迟与重定位行为 |
| 将 X3 姿态接入 Apple 空间音频渲染 | Mac 路径尚未证实；iOS 新官方接口值得单独评估 | 原始 IMU/姿态传输接口、时间戳、坐标系、系统平台支持；有模式开关不等于有传感器数据流 |
| iCloud 配对同步 | 当前 Mac App 无可直接交付路径 | 耳机端相关协议与密钥管理、Apple 设备端协同；同步 App 设置不能代替同步蓝牙配对关系 |
| 离线 Find My 网络 | 当前方案不可直接实现；有研究性替代路线 | 耳机或盒子离开 Mac 后自主发送定位信标的固件能力及密钥生命周期；现有 X3 未验证相关接口 |

以上判断均限定“原厂固件、只开发 Mac App”。如果掌握耳机固件源码/SDK、传感器接口或增加外部硬件，应重新评估，而非宣称物理上永远不能实现。

## Apple 新官方接口：不能遗漏的变化

### 邻近配对

[Apple 官方 Proximity-triggered pairing](https://developer.apple.com/proximity-pairing/)列明：面向欧盟、iPhone iOS 26.5 及以上；需要配件自认证、Apple 服务端注册以及 iOS 配套 App。申请面向以自身品牌面向欧盟开发和销售配件的组织开发者。由此不能推导个人 Mac App 可把任意现有第三方耳机注册为 AirPods。

### 自动音频切换

[AudioAccessoryKit](https://developer.apple.com/documentation/audioaccessorykit)明确支持 iPhone/iPad；开发测试可在任何地区进行，用户安装使用要求设备位于欧盟且 Apple Account 国家/地区为欧盟。

[官方接入指南](https://developer.apple.com/documentation/audioaccessorykit/supporting-automatic-audio-switching)要求配套 App 通过 AccessorySetupKit 完成配对/注册，并持续报告佩戴位置和已连接音源。这是一条值得研究的正式兼容路线，但需要 iOS App 与可靠的 X3 状态/控制接口，不能仅给现有 macOS 菜单栏加一个开关完成。

### 第三方头部追踪

[AudioAccessoryHeadTracking](https://developer.apple.com/documentation/audioaccessorykit/audioaccessoryheadtracking)及其 [Session](https://developer.apple.com/documentation/audioaccessorykit/audioaccessoryheadtracking/session)已出现在 Apple 官方文档。对应文档 JSON 的平台元数据列出 iOS 27.0；页面缓存仍有 Beta 标签，交付时须再次核实 SDK 和正式可用性。

官方 `Session.sendDataToAudioExtension(_:)` 摘要明确用于把配件 IMU 帧交给 Spatial Audio renderer。由此可见，“第三方数据永远无法接入 Apple 渲染”不是准确结论。它目前不能证明 macOS 有同等接口，也没有解决 X3 是否输出所需 IMU 流的问题。具体地区/授权/传输扩展要求需在此分支实现前核实。

[CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)则是获取系统已支持耳机运动数据的消费接口；不能把它当成任意蓝牙耳机姿态注入系统的入口。

## Find My 的两条路线

[Apple 官方 Find My accessory](https://developer.apple.com/find-my/)要求通过 MFi 获取规范和开发资源，是配件级接入工作。不能仅因为耳机有 BLE 就宣称已能进入官方“查找”。

[OpenHaystack 研究项目](https://github.com/seemoo-lab/openhaystack)证明非 Apple 硬件可以通过特定 BLE 定位信标使用相关网络。其架构包括配件固件与位置报告客户端；不等同把任意现有耳机添加到原生 Find My。没有 X3 广播/固件控制接口时，Mac 无法替耳机在离开 Mac 后继续广播；给盒子外挂标签追踪的也是标签。

BLE 众包定位不以 GPS 或 UWB 为前提；精确方向/距离查找属于另一个硬件能力问题。本次没有证据证明 X3 具备 UWB，不把它列为可软件解锁的能力。

## 建议的下一轮验证顺序

1. **内置头部追踪效果**：在现有受控模式设置和恢复流程下，比对关闭/固定/跟随的转头表现，先确认耳机自身已经能提供多少体验。验收需用户听感或合适声学测量，ACK 不替代听感。
2. **原始姿态是否外传**：查上游/厂商协议、观察已知通知，必要时采集用户授权的官方手机 App 交互日志；未知写命令先搞清意义，不盲扫命令或借用 AirPods/Nord 命令发送给 X3。
3. **连接浮层与开盖事件**：连接自动弹出可直接开发；开盖触发必须先建立与本机耳机可识别信号的可靠对应，不能假造盒盖状态。
4. **双设备仲裁**：记录 Mac 播放、手机播放、来电、挂断恢复的真实行为，再决定 Mac 输出跟随和手动抢回控制。测试动作和恢复要求单独设计。
5. **iOS 官方接入分支**：在平台、地区条件与 X3 数据通道明确后，再研究 AudioAccessoryKit / 头部追踪传输扩展；不把它混为现有 Mac 版已支持。

优先级不包括刷入洛达固件、伪造系统配对、恢复出厂或修改已有配对。本次调研没有执行上述动作。
