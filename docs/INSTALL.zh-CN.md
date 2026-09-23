# Enco X3 for Mac 安装说明

适用于 Apple Silicon（M 系列芯片）Mac。最低部署目标 macOS 13，已实机验证环境为 macOS 27.2；其他系统及固件尚未实机验证。此安装包不包含 Intel 版本。

## 安装

1. 退出正在运行的 Enco X3。
2. 打开 DMG，把 **Enco X3.app** 拖入 **Applications（应用程序）**，然后推出磁盘映像。也可以解压 ZIP，将 App 放进应用程序目录。
3. 在 macOS 蓝牙设置中连接已经配对的 OPPO Enco X3，再从应用程序目录启动 App。
4. 允许 App 使用蓝牙，点击菜单栏的耳机图标打开控制面板。不要同时运行多个副本或诊断工具。

如果之前安装在 `~/Applications`，可以把新 App 拖到该目录覆盖旧版，避免保留两个副本。

## 首次打开

本版采用本地 ad-hoc 签名，**没有 Developer ID 签名，也没有 Apple 公证**。从网络下载后，macOS 可能阻止首次启动。确认下载来源后，按 Apple 官方说明在“系统设置 → 隐私与安全性”中使用“仍要打开”。不需要关闭系统 Gatekeeper。

Apple 说明：https://support.apple.com/102445

## 使用提示

- 首次控制连接可能超时一次，应用会自动重试；这不等于系统音频连接断开。
- 盒电量未上报时显示 `--`；本机实测需要一只耳机入盒并保持盒盖打开。
- 双设备列表只读；空间音效控制的是耳机自身模式，不代表 Apple 动态头部追踪。
- 本应用不配对/取消配对，不恢复出厂，不更新固件。
- 卸载时退出 App 并移除应用程序即可；不会删除系统蓝牙配对。

源代码、GPL-3.0-or-later 许可证、功能与已知限制：
https://github.com/JonathanChan-geek/EncoX3-Mac

反馈：https://github.com/JonathanChan-geek/EncoX3-Mac/issues
