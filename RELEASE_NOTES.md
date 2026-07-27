# XDVPN v1.5.8

## 更新了什么

- 连接期间可以在纯代理、VPN 分流和 VPN 全局三种模式之间切换；确认后会按当前真实模式清理并自动重连。
- 新增 Wi-Fi 按需连接规则，可按当前 SSID 自动连接或断开 VPN，并支持独立管理规则。
- 修复全局模式启用 def1 路由后，重复物理接口条目被误判为换网、导致连接与重建死循环的问题。
- 长时间连接时持续跟踪 OpenConnect 内部重连后的最新 tunnel session 和 utun 接口。
- 增加连接超时、取消连接，以及换网、休眠唤醒和疑似黑洞后的清理重连。
- 降低连接状态和隐藏主窗口时的 CPU 占用，减少无效的 SwiftUI 刷新和菜单栏图标重绘。
- 更新窗口现在会直接展示每个版本的“更新了什么”。

## 安装

1. 下载下面的 `XDVPN-v1.5.8.zip` 并解压。
2. 把 `XDVPN.app` 拖进 `/Applications/`。
3. 双击 `/Applications/XDVPN.app`；如果被 Gatekeeper 拦截，在“系统设置 → 隐私与安全性”中选择“仍要打开”。
4. 菜单栏出现锁盾图标后，首次使用请点“一键配置”安装系统组件。

## OpenConnect

OpenConnect 9.21 已随 XDVPN.app 内置，用户机器不需要预装 Homebrew 或 OpenConnect。

## 说明

- 未经 Apple 公证：个人自用项目，没有 Apple Developer 账号。源码公开，可自行运行 `./build.sh` 从头构建。
- 支持 macOS 14+。
