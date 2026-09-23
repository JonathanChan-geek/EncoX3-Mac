# 菜单栏视觉重设计

用户反馈：已有控制可用，但默认按钮堆叠、整片灰底、无设备视觉主体，像调试面板。目标是日常消费级原生体验。

## 已查看的官方参考

- [Apple AirPods 听音模式说明](https://support.apple.com/en-us/108918)
- [Apple macOS 菜单栏截图](https://cdsassets.apple.com/live/7WUAS350/images/airpods/macos-27-golden-gate-menu-bar-airpods-listening-mode-adaptive-slider.png)
- [Apple iOS AirPods 设备页截图](https://cdsassets.apple.com/live/7WUAS350/images/airpods/ios-27-iphone-17-pro-settings-airpods-listening-mode-adaptive-slider.png)
- [HeyMelody 官方 Google Play 页面及截图](https://play.google.com/store/apps/details?id=com.heytap.headset)

2026-09-23 用浏览器实际查看截图。Apple macOS 参考为紧凑设备行、图标、清晰选中标记及分层设置；iOS 参考把耳机/盒子形象与电量放在顶部，听音模式使用统一的图标分段控件；HeyMelody 官方预览也以设备形象和电量为主体。

## 本项目采用的设计

- 设备标题、连接状态与少量辅助操作组成顶栏；移除重复更新时间。
- 左耳、右耳、盒子采用原创代码绘制的小型插画，电量形成统一视觉组，不用头戴耳机图标代替入耳耳机。
- 噪声控制为一组四模式选择；降噪档位是一条分段控件，不能散落为四个系统小按钮。
- 音效使用整行菜单入口、对齐的当前值、清晰的选中标记。
- 双设备为紧凑列表，私人名称不进入文档或参考素材。
- 浅色/深色语义配色、蓝色选中态、充足点击区域。常驻说明移到帮助提示/关于，故障仍需明确显示。

参考的是信息层级、控件组织与视觉节奏；不复制品牌图像、App 资源或宣称 Apple 官方界面。功能和协议路径保持独立，所有现有能力边界不变。

## 验收方式

以实际编译运行的 SwiftUI 界面截图为准；检查完整布局、按钮与选中态、菜单、长设备名、未知电量及深浅外观。查看渲染结果后再决定是否合格。纯视觉改变不新增复述样式实现的单元测试。

额外造型核对：[OPPO Enco X3 官方产品页](https://www.opposhop.cn/cn/web/products/31828.html)。只用于核对短柄与盒子轮廓，不把商城图片或品牌资源打包进应用。

## 实现与实机检查

- 0.2：380pt 宽的 SwiftUI 面板，AppKit 原生弹出菜单，左右耳与盒子原创矢量插画，四主模式、四降噪档位、两条音效设置行和双设备列表。
- 实际截图发现 SwiftUI Menu 在此 macOS 上压缩自定义标签、丢失当前值，改用完整行 Button + NSMenu，菜单选中态来自设备回读。
- 启动路径将 IOBluetooth 的首次只读初始化放到单次后台任务中，避免系统授权等待阻塞主界面。传输与事务仍运行于原主线程 run loop，未改协议或控制数值。
- 本机系统日志确认本地 ad-hoc 重新构建后发生 `Failed to match existing code requirement`，继而 `AUTHREQ_PROMPTING` 请求 BluetoothAlways；因此新二进制可能需要重新允许蓝牙。没有重置 TCC、蓝牙守护进程、系统配对或固件。
- `--appearance=light|dark` 仅用于本应用临时视觉验收；正常启动跟随系统，不写系统外观设置。
- 本次设计验收不执行耳机设置写入。已有控制协议验收见 `docs/evidence/`；不把历史的硬件测试当成本轮重测。

### 最终验收状态

- 浅色、强制深色均已查看真实 App 截图：设备插画、音效整行标签、未知电量、故障提示可见，无相互遮挡。深色修正同时传递 AppKit appearance 和 SwiftUI preferredColorScheme；不带参数保留系统继承。
- “更多 → 关于”已实际打开关闭，显示 0.2 (2) 与 GPL/Apple 能力边界；“更多 → 退出”已验证进程正常退出。
- 最终 Release 构建与已安装应用的严格签名校验通过，`git diff --check` 通过。Core、Bluetooth、Diagnostics 和测试文件无本轮改动。
- 14:13 权限等待解除，最终二进制已连接 RFCOMM channel 15。真实面板显示左右耳 100%、盒子未知、噪声关闭、EQ 自定义、空间音效关闭和两台已连接设备；完整布局无裁切，更新时间持续推进。均衡器菜单实际展开六个预设，空间菜单实际展开关闭/固定/跟随三个选项，再用 Escape 关闭，未发送设置写入。菜单勾选由源码的设备回读值映射；工具截图仅捕获主面板，未据此声称看到了浮动菜单勾选图形。
- 交付启动已移除外观覆盖，使用系统外观；仅保留诊断日志开关，不触发任何设置写入。
- 授权后再退出并启动同一个安装包：框架初始化完成，未再卡在授权；首次 RFCOMM 打开仍出现 12 秒超时，自动重试后连接成功并回读 PID/ANC/EQ/空间/双设备。记录为当前限制：启动时控制通道可能需要一次重试，不能宣称即时连接；不影响现有系统音频配对。

### 充电盒图形遮挡修正

用户局部截图指出充电盒图形侵入名称区域，之前“无相互遮挡”的结论漏检了这一处。此次由当前 Agent 直接修正：盒体用明确的 38×30pt 圆角形状及 overlay 绘制，整个插画限制在 44×44pt 区域；三列均使用 44pt 插画、14pt 名称、20pt 数值和两段 5pt 间距，总高 88pt。插画边界裁剪防止绘制侵入文字，盒体阴影留在插画区内。实际运行截图已核对充电盒与名称间有清晰留白，三列名称和电量对齐。Release 构建、严格签名校验、diff whitespace 检查通过，未修改控制协议或耳机设置。
